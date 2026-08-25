using PlantGeom # For the growth and visualization API
using GLMakie, AlgebraOfGraphics
using ArchimedLight
using PlantMeteo
using FileIO, MultiScaleTreeGraph, GeometryBasics
using CoordinateTransformations, LinearAlgebra, StaticArrays
using CSV, DataFrames, Dates

# doe = CSV.read("0-data/doe.csv", DataFrame)
# filter!(x -> x.row_orientation == "N-S", doe)
function read_plant(obj_path::AbstractString, mtg_path::AbstractString)
    # obj_path = normpath("./mtg_obj/usm_1_2.5D_2018-10-09_1.obj")
    # mtg_path = joinpath(dirname(obj_path), first(split(basename(obj_path), ".")) * ".mtg")
    mesh_plant = load(obj_path)
    splitted_mesh = split_mesh(GeometryBasics.Mesh(mesh_plant))
    # mesh_plant[:object] #! use this to index by object id!!
    length(splitted_mesh) == 0 && return nothing
    # Map the meshes object ids from the .obj file to the splitted meshes, and scale from cm to m:
    scale = 0.01 ##check if need to update
    meshes = Dict{String,GeometryBasics.Mesh}()
    for (i, obj) in enumerate(mesh_plant[:object])
        # i=1; obj = mesh_plant[:object][i]
        mesh_ = splitted_mesh[i]
        c, f = coordinates(mesh_), faces(mesh_)
        meshes[split(obj, "_")[end]] = GeometryBasics.Mesh(scale * c, f)
    end

    mtg = read_mtg(mtg_path, NodeMTG)

    # Re-attach the geometry to the MTG using the Ids from the .obj files and the MTG attribute
    traverse!(mtg) do node
        Id = string(node[:Id])
        if Id != "nothing" && (haskey(meshes, Id) || haskey(meshes, string(parse(Int, Id) + 10000000)))
            if symbol(node) == :Stem
                node[:geometry] = PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[Id]))
            end
            # Senescent meshes are defined with Id + 10000000, so we check if the senescent mesh exists and add it as a child node to the MTG.
            active_leaf = MultiScaleTreeGraph.addchild!(
                node,
                NodeMTG("/", "LeafSection", 1, MultiScaleTreeGraph.scale(node)+1),
                Dict(
                    :geometry => PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[Id])),
                    :state=>"active",
                )
            )
            # node[:geometry] = PlantGeom.Geometry(
            #     ref_mesh=RefMesh(Id, meshes[Id]),
            # )
            candidate_senescent_id = string(parse(Int, Id) + 10000000)
            if haskey(meshes, candidate_senescent_id)
                MultiScaleTreeGraph.addchild!(
                    active_leaf, NodeMTG("<", "LeafSection", 2, MultiScaleTreeGraph.scale(node)+1),
                    Dict(
                        :geometry => PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[candidate_senescent_id])),
                        :state=>"senescent",
                    )
                )
            end
        end
    end

    return mtg
end

# Read the domains of each situation (usm):
domains = CSV.read("0-data/domains.csv", DataFrame)
domains.usms = [parse.(Int, split(i, "_")[2]) for i in domains.usms]
domains.x_first_corner = domains.x_first_corner .* 0.01
domains.y_first_corner = domains.y_first_corner .* 0.01
domains.x_last_corner = domains.x_last_corner .* 0.01
domains.y_last_corner = domains.y_last_corner .* 0.01

# Parsing the files into situations (beginning of the name), date of simulation, and index of the plant (there are four plants)
all_files = readdir("0-data/mtg_obj")
mtgs = filter(f -> endswith(f, ".mtg"), all_files)
df = DataFrame(usm=Int[], algo=String[], date=Date[], index=Int[],)
for i in mtgs # i = mtgs[1]
    splitted_name = split(i, "_")
    _, usm_str, algo, date_str, index_str = split(i, "_")
    push!(
        df,
        (
            usm=parse(Int, usm_str),
            algo=algo,
            date=Date(date_str),
            index=parse(Int, first(split(index_str, "."))),
        )
    )
end
sort!(df, [:usm, :algo, :date, :index])


# Archimed options
options = LightOptions(
    turtle_sectors=46,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
    cache_radiation=false,
    all_in_turtle=true,
    radiation_timestep_minutes=10,
    nir_interception=false,
)

meteo_stics = CSV.read("0-data/ntarla_corr.2018", DataFrame, header=[:station, :year, :month, :day, :dayofyear, :Tmin, :Tmax, :Ri_SW_q, :etp, :Precipitations, :Wind, :e, :Ca], delim=(' '))
meteo_ = Weather([(
    date=Date(row.year, row.month, row.day),
    hour_start=Time(0),
    duration=86400.0,
    latitude=12.58,
    Ri_SW_f=row.Ri_SW_q / 86400.0,
    Ri_PAR_f=row.Ri_SW_q .* 0.48 / 86400.0,
    T=(row.Tmin+row.Tmax)/2,
    Wind=row.Wind,
    Rh=PlantMeteo.rh_from_e(row.e, (row.Tmin+row.Tmax)/2),
) for row in eachrow(meteo_stics)])

meteo = prepare_meteo(meteo_, options)

models = models_for(
    "*" => (
        "Stem" => translucent(par=0.15, nir=0.90),
        "LeafSection" => translucent(par=0.15, nir=0.90),
    ),
    "pavement" => (
        "Cobblestone" => translucent(par=0.12, nir=0.60),
    ),
)

workspace = "0-data/mtg_obj" # where the input files are stored (.obj and .mtg files)


function run_usm(scenes, dates, options, meteo, models; output_path=nothing)
    x_min, y_min, x_max, y_max = scenes[1].scene_xy_bounds
    # Build a lookup from Date -> meteo row and pick the rows matching the provided dates
    meteo_map = Dict(r.date => r for r in meteo)
    meteo_growth = Vector{eltype(meteo)}(undef, length(dates))
    for (i, d) in enumerate(dates)
        if !haskey(meteo_map, d)
            error("No meteo data for date $(d). Ensure weather file contains this date.")
        end
        meteo_growth[i] = meteo_map[d]
    end

    # Run the simulations:
    series = Vector{ArchimedLight.LightStepResult}(undef, length(scenes))
    sim = LightSimulation(scenes[1], models; options=options)

    sim_time = @time begin
        for (i, row) in enumerate(meteo_growth) # i = 1; row = meteo[177]
            i > 1 && update_scene!(sim, scenes[i])
            series[i] = run_light(sim, row)
        end
    end
    # 90s for the strip intercrop with 2 maize and 6 sorghum plants.

    scene_area = (x_max - x_min) * (y_max - y_min)
    apar_maize_plants = light_metric_values(
        sim,
        series,
        :absorbed_par_energy;
        species="maize",
        sink=DataFrame
    )

    apar_sorghum_plants = light_metric_values(
        sim,
        series,
        :absorbed_par_energy;
        species="sorghum",
        sink=DataFrame
    )

    apar_ground = light_metric_values(
        sim,
        series,
        :absorbed_par_energy;
        species="pavement",
        sink=DataFrame
    )

    apar_plants = vcat(apar_maize_plants, apar_sorghum_plants)
    df_apar_all = vcat(apar_plants, apar_ground)
    df_apar_combined = combine(
        groupby(df_apar_all, [:group, :object_id, :step_number]),
        :value => sum => :apar_sum
    )
    sort!(df_apar_combined, [:step_number, :group, :object_id])
    # Compute incoming PAR energy for each matched meteo row and attach the simulation date
    Ri_PAR_q = [row.Ri_PAR_f * row.duration * scene_area for row in meteo_growth]
    df_meteo = DataFrame(step_number = 1:length(meteo_growth), date = dates, Ri_PAR_q = Ri_PAR_q)
    joined_df = leftjoin(df_apar_combined, df_meteo, on=:step_number)
    joined_df.fapar = joined_df.apar_sum ./ joined_df.Ri_PAR_q

    output_path !== nothing && CSV.write(output_path, joined_df)

    return series, joined_df
end

df_gp = combine(groupby(df, [:usm, :algo, :date]), threads=true) do subdf
    println("Processing situation $(subdf.usm[1]), algorithm $(subdf.algo[1]), date $(subdf.date[1])")
    x_min, y_min, x_max, y_max = domains[domains.usms .== subdf.usm[1], 2:end][1, :]
    PlantGeom.make_scene(domain=(x_min, y_min, x_max, y_max)) do s
        for row in eachrow(subdf)
            mtg_ = read_plant(
                joinpath(workspace, "usm_$(row.usm)_$(row.algo)_$(row.date)_$(row.index).obj"),
                joinpath(workspace, "usm_$(row.usm)_$(row.algo)_$(row.date)_$(row.index).mtg"),
            )
            isnothing(mtg_) && continue
            add_plant!(s, mtg_; group=mtg_.species, id=row.index + 1)#, at=(0.5, 0.5, 0.0))
        end
        add_ground!(s; nx=20, ny=20, group="pavement", type="Cobblestone")
    end
end

all_time = @elapsed let
    for gp in groupby(df_gp, [:usm, :algo])
        usm = first(gp.usm)
        algo = first(gp.algo)
        sim_time = @elapsed begin
            run_usm(
                gp[:, 4], gp[:, 3], options, meteo, models;
                output_path="2-results/simulations/fapar_usm_$(usm)_$(algo).csv"
            )
        end
        println("Simulation for usm $(usm), algo $(algo) took $(sim_time) seconds.")
    end
end
println("All simulations took $(all_time) seconds.")
# All simulations took 3161.840156083 seconds.

#. Running one simulation only:
algo = "Beer"
usm = 14
df_gp_usm = filter(row -> row.usm == usm && row.algo == algo, df_gp)
@time series, joined_df = run_usm(
    df_gp_usm[:, 4], df_gp_usm[:, 3], options, meteo, models;
    output_path="2-results/simulations/fapar_usm_$(usm)_$(algo).csv"
)

df = CSV.read(readdir("2-results/simulations", join=true), DataFrame, source=:filename)
df.filename .= basename.(df.filename)
df.usm .= [parse(Int, split(i, "_", limit=4)[3]) for i in df.filename]
df.algo .= [split(split(i, "_", limit=4)[end], ".csv")[1] for i in df.filename]

df_per_species = combine(
    groupby(df, [:usm, :algo, :step_number, :group]),
    :apar_sum => sum => :apar_sum,
    :Ri_PAR_q => sum => :Ri_PAR_q,
)

DataFrames.transform!(
    groupby(df_per_species, [:usm, :algo, :group]),
    [:apar_sum, :Ri_PAR_q] => ((x, y) -> x ./ y) => :fapar,
)

p_species =
    data(df_per_species) *
    mapping(:step_number, :fapar, color=:group, col=:algo, row=:usm) *
    visual(Lines)
f_species = draw(p_species)
save("2-results/fapar_per_species.png", f_species, px_per_unit=3, size=(1500, 1600))