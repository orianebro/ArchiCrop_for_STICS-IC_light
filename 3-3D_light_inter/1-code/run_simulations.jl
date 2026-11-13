# Include through Kaimon. Inclusion defines functions only; it starts no batch.
using ArchimedLight, PlantMeteo, PlantGeom, CSV, DataFrames, Dates
isdefined(@__MODULE__, :CropVisuals) || include(joinpath(@__DIR__, "crop_visuals.jl"))

read_stics_weather(paths;latitude) = CropVisuals.SticsWeather.read_stics_weather(paths;latitude)

function compact_simulation_index(;usms,algorithms=["2.5D","Beer"],source=CropVisuals.COMPACT_ASSETS)
    isempty(usms) && error("Select at least one USM explicitly")
    table=DataFrame(usm=Int[],algo=String[],date=Date[],scene_folder=String[])
    for algorithm in algorithms
        algorithm in ("2.5D","Beer") || error("Unknown algorithm $algorithm")
        rows=CropVisuals.compact_scene_index(usms;algo=algorithm,source)
        for row in eachrow(rows)
            push!(table,(row.usm,algorithm,row.date,row.scene_folder))
        end
    end
    sort!(table,[:usm,:algo,:date])
    allunique(Tuple.(eachrow(table[:,[:usm,:algo,:date]]))) || error("Duplicate case/date")
    return table
end

function prepared_weather_by_site(options)
    Dict(site=>prepare_meteo(read_stics_weather(paths;latitude),options)
        for (site,(paths,latitude)) in CropVisuals.SticsWeather.weather_paths(joinpath(CropVisuals.ROOT,"0-data")))
end

weather_site_for_usm(usm,dates,available_dates) =
    CropVisuals.SticsWeather.weather_site_for_dates(dates,available_dates)

function physical_fapar(absorbed,incident)
    isfinite(absorbed) && isfinite(incident) && absorbed>=0 && incident>=0 ||
        error("Invalid absorbed/incident PAR energy")
    incident>0 && return absorbed/incident
    iszero(absorbed) && return missing
    error("Positive absorbed PAR with zero incident PAR")
end

"""Sum energy across plants, retaining the once-per-cell incident denominator."""
function species_fapar(table)
    needed=[:date,:step_number,:group,:apar_sum,:Ri_PAR_q]
    all(c->c in propertynames(table),needed) || error("Missing plant energy/date columns")
    keys=[c for c in (:usm,:algo,:date,:step_number,:group) if c in propertynames(table)]
    cell_keys=filter(!=(:group),keys)
    for rows in groupby(table,cell_keys)
        length(unique(rows.Ri_PAR_q))==1 || throw(ArgumentError("Incident PAR differs within one cell/date"))
    end
    result=combine(groupby(table,keys),:apar_sum=>sum=>:apar_sum,:Ri_PAR_q=>first=>:Ri_PAR_q)
    result.fapar=[physical_fapar(a,i) for (a,i) in zip(result.apar_sum,result.Ri_PAR_q)]
    return result
end

"""Run one explicit case, holding only one assembled scene/result by default.

Input dates must be unique and chronological. The returned table contains plant
energy in J and incident PAR over the WHOLE cell once per timestep (repeated on
plant rows for convenience). Set retain_series=true only if retained radiative
results are needed for a later diagnostic.
"""
function run_usm(scenes,dates,options,meteo,models;output_path=nothing,retain_series=false)
    length(scenes)==length(dates)>0 || error("Scene/date lengths differ or are empty")
    issorted(dates) && allunique(dates) || error("Dates must be unique and chronological")
    load_scene(value)=value isa AbstractString ? CropVisuals.periodic_scene(value) : value
    first_scene=load_scene(first(scenes))
    bounds=first_scene.scene_xy_bounds
    area=(bounds[3]-bounds[1])*(bounds[4]-bounds[2])
    meteo_map=Dict(row.date=>row for row in meteo)
    length(meteo_map)==length(meteo) || error("Duplicate prepared weather dates")
    all(day->haskey(meteo_map,day),dates) || error("Missing weather for scene dates")
    sim=LightSimulation(first_scene,models;options)
    retained=retain_series ? ArchimedLight.LightStepResult[] : nothing
    plants=DataFrame()
    for (i,day) in enumerate(dates)
        if i>1
            scene=load_scene(scenes[i])
            maximum(abs.(scene.scene_xy_bounds.-bounds))<1e-9 || error("Scene domain changes with date")
            update_scene!(sim,scene)
        end
        row=meteo_map[day]
        result=run_light(sim,row)
        retain_series && push!(retained,result)
        # Query the result while its scene is live. Dynamic snapshots also retain
        # these identities, but streaming avoids retaining every daily mesh.
        components=light_metric_values(sim,result,:absorbed_par_energy;sink=DataFrame)
        components=filter(r->r.group in ("maize","sorghum","wheat","pavement"),components)
        daily=combine(groupby(components,[:group,:object_id]),:value=>sum=>:apar_sum)
        incoming=row.Ri_PAR_f*PlantMeteo.duration_seconds(row.duration)*area
        daily.step_number=fill(i,nrow(daily));daily.date=fill(Date(day),nrow(daily))
        daily.Ri_PAR_q=fill(incoming,nrow(daily))
        daily.fapar=[physical_fapar(a,incoming) for a in daily.apar_sum]
        append!(plants,daily;cols=:union)
        (i==1 || i%30==0 || i==length(dates)) && @info "Light case progress" date=day step=i total=length(dates)
    end
    sort!(plants,[:step_number,:group,:object_id])
    isnothing(output_path) || CSV.write(output_path,plants)
    return retained,plants
end


"""Run selected current scenes and write per-plant and species CSV results."""
function run_light_batch(;usms=collect(1:63), algorithms=["2.5D","Beer"],
        source=CropVisuals.COMPACT_ASSETS,
        output_dir=joinpath(CropVisuals.ROOT,"2-results","simulations_code_shape2_2026-11-10"),
        options=CropVisuals.light_options(),models=CropVisuals.light_models())
    index=compact_simulation_index(;usms,algorithms,source)
    meteo=prepared_weather_by_site(options)
    covered=Dict(site=>Set(row.date for row in weather) for (site,weather) in meteo)
    mkpath(output_dir)
    all_species=DataFrame()
    for rows in groupby(index,[:usm,:algo])
        usm,algo=first(rows.usm),first(rows.algo)
        site=weather_site_for_usm(usm,rows.date,covered)
        _,table=run_usm(rows.scene_folder,rows.date,options,meteo[site],models)
        table.usm=fill(usm,nrow(table));table.algo=fill(algo,nrow(table))
        CSV.write(joinpath(output_dir,"fapar_usm_$(usm)_$(algo).csv"),table)
        append!(all_species,species_fapar(table);cols=:union)
        GC.gc()
    end
    summary=joinpath(output_dir,"fapar_per_species.csv")
    CSV.write(summary,all_species)
    return (;output_dir=abspath(output_dir),cases=length(groupby(index,[:usm,:algo])),
        scene_dates=nrow(index),species_summary=summary)
end
