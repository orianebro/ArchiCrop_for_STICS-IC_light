using PlantGeom # For the growth and visualization API
using GLMakie, AlgebraOfGraphics
using ArchimedLight
using PlantMeteo
using FileIO, MultiScaleTreeGraph, GeometryBasics
using CoordinateTransformations, LinearAlgebra, StaticArrays
using CSV, DataFrames, Dates

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

# Read one plant:
# obj_path = normpath("0-data/mtg_obj/usm_1_Beer_2018-07-15_0.obj")
# mtg_path = joinpath(dirname(obj_path), first(split(basename(obj_path), ".")) * ".mtg")
# mtg = read_plant(obj_path, mtg_path)
# plantviz(mtg)

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

workspace = "0-data/mtg_obj" # where the input files are stored (.obj and .mtg files)

df_gp = combine(groupby(df, [:usm, :algo, :date]), threads=true) do subdf
    println("Processing situation $(subdf.usm[1]), algorithm $(subdf.algo[1]), date $(subdf.date[1])")
    x_min, y_min, x_max, y_max = domains[domains.usms .== subdf.usm[1], 2:end][1, :]
    scene_ = PlantGeom.make_scene(domain=(x_min, y_min, x_max, y_max)) do s
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
    scene_
end

# Checking one of the scenes in 3D:
mesh(df_gp[80, 4].merged_mesh, color=:green)

###################### Visualizing USM 4 growth ######################
let
    usm = 4 # Choose the usm index here
    algo = "Beer" # Choose the algorithm here ("Beer" or "2.5D")
    df_gp_usm = filter(row -> row.usm == usm && row.algo == algo, df_gp)
    x_min, y_min, x_max, y_max = domains[domains.usms .== usm, 2:end][1, :]

    # Make a video of the plot (visualizing plant growth and senescence):
    let
        buffer = 0.5 # Increased scene limits for visualization
        # Make a video of the plot (visualizing plant growth):
        fig = Figure(size=(900, 700))
        ax = Axis3(
            fig[1, 1],
            aspect=:data,
            title="USM $usm $(df_gp_usm[1,:date])",
            xlabel="x (m)",
            ylabel="y (m)",
            zlabel="z (m)",
            limits=((x_min - buffer, x_max + buffer), (y_min - buffer, y_max + buffer), (0, 3.5))
        )
        legend_elems = [
            PolyElement(color=:green, strokecolor=:black),   # plant
            PolyElement(color=:yellow, strokecolor=:black),  # senescent leaves
            PolyElement(color=:gray, strokecolor=:black),    # ground
        ]

        legend_labels = ["Leaves / internodes", "Senescent leaves", "Ground"]

        Legend(
            fig[1, 2],
            legend_elems,
            legend_labels;
            title="Mesh type",
            framevisible=true,
            tellheight=false
        )

        traverse!(df_gp_usm[1, 4].mtg) do node
            !PlantGeom.has_geometry(node) && return
            if symbol(node) == :Stem
                node.color = :brown
            elseif symbol(node) == :LeafSection
                node.color = node[:state] == "active" ? :green : :yellow
            else
                node.color = :gray
            end
        end
        p = plantviz!(ax, df_gp_usm[1, 4].mtg; color=:color)
        record(fig, "2-results/scene_usm_$(usm)_colored.mp4", 2:nrow(df_gp_usm), framerate=1) do frame
            traverse!(df_gp_usm[frame, 4].mtg) do node
                !PlantGeom.has_geometry(node) && return
                if symbol(node) == :Stem
                    node.color = :brown
                elseif symbol(node) == :LeafSection
                    node.color = node[:state] == "active" ? :green : :yellow
                else
                    node.color = :gray
                end
            end
            Makie.update!(p, arg1=df_gp_usm[frame, 4].mtg)#, color=:color)
            ax.title = "USM $usm $(df_gp_usm[frame,:date])"
        end
    end
end

###################### Visualizing USM 5 dynamic light interception ######################

usm = 5 # Choose the usm index here
algo = "Beer" # Choose the algorithm here ("Beer" or "2.5D")
df_gp_usm = filter(row -> row.usm == usm && row.algo == algo, df_gp)
x_min, y_min, x_max, y_max = domains[domains.usms .== usm, 2:end][1, :]

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
    # hour_end=Time(23, 59, 59, 999),
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
sowing_day = 177 #! this shouldn't be hard-coded
meteo_growth = meteo[sowing_day:(sowing_day+nrow(df_gp_usm)-1)]
series = Vector{ArchimedLight.LightStepResult}(undef, nrow(df_gp_usm))
scene = df_gp_usm[1, 4]
sim = LightSimulation(scene, models; options=options)

@time begin
    for (i, row) in enumerate(meteo_growth) # i = 1; row = meteo[177]
        # scene = df_gp_usm_date[4]
        scene = df_gp_usm[i, 4]
        i > 1 && update_scene!(sim, scene)
        light = run_light(sim, row)
        series[i] = light
    end
end

# Make a video of the light simulation:
function plot_3D_interception(
    df_gp_usm, series, meteo_growth, usm, domain;
    colorrange=nothing,
    output_path="2-results/aPAR_W_m2_usm_$usm.mp4",
    variable=:Ra_PAR_f,
    tiled=false,
)
    x_min, y_min, x_max, y_max = domain
    @assert variable in (:Ra_PAR_f, :Ra_PAR_q) "Variable must be either :Ra_PAR_f or :Ra_PAR_q"
    var_label = variable == :Ra_PAR_f ? "aPAR (W m⁻²)" : "aPAR (J)"
    buffer = 0.5 # Increased scene limits for visualization
    nx = ny = 10

    if tiled
        dx = x_max - x_min
        dy = y_max - y_min
        # Match ArchimedLight's centered offsets, including for even tile counts.
        x_offsets = (-(nx÷2)):(nx-nx÷2-1)
        y_offsets = (-(ny÷2)):(ny-ny÷2-1)
        plot_limits = (
            (
                x_min + first(x_offsets) * dx - buffer,
                x_max + last(x_offsets) * dx + buffer,
            ),
            (
                y_min + first(y_offsets) * dy - buffer,
                y_max + last(y_offsets) * dy + buffer,
            ),
            (0, 3.5),
        )
    else
        plot_limits = (
            (x_min - buffer, x_max + buffer),
            (y_min - buffer, y_max + buffer),
            (0, 3.5),
        )
    end

    fig = Figure(size=(900, 700))
    ax = Axis3(
        fig[1, 1],
        aspect=:data,
        azimuth=(-π / 4),
        elevation=π / 6,
        title="USM $usm on $(meteo_growth[1].date)",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        limits=plot_limits,
    )

    if !tiled
        p = ArchimedLight.lightplot!(ax, series[1]; color=variable, colormap=:thermal, colorrange=colorrange)

    else
        scene_tiled = ArchimedLight.tile_light_geometry(df_gp_usm[1, 4], series[1]; nx=nx, ny=ny)
        p = ArchimedLight.lightplot!(ax, scene_tiled, series[1]; color=variable, colormap=:thermal, colorrange=colorrange)
    end

    Colorbar(fig[1, 2], p, label=var_label)
    record(fig, output_path, 2:length(series), framerate=1) do frame
        if !tiled
            Makie.update!(p, arg1=series[frame])
        else
            scene_tiled = ArchimedLight.tile_light_geometry(df_gp_usm[frame, 4], series[frame]; nx=nx, ny=ny)
            Makie.update!(p; arg1=(scene_tiled, series[frame]))
        end
        ax.title = "USM $usm on $(meteo_growth[frame].date)"
    end

    # scene_tiled = ArchimedLight.tile_light_geometry(scene_day_indexed, series[day_index_tiled]; nx=10, ny=10)
    # f_tiled, ax_tiled, p_tiled = ArchimedLight.lightplot(scene_tiled, series[day_index_tiled]; color=:Ra_PAR_f, colormap=:thermal)
    fig
end

plot_3D_interception(
    df_gp_usm, series, meteo_growth, usm, (x_min, y_min, x_max, y_max);
    colorrange=(0, 1e-4),
    output_path="2-results/aPAR_W_m2_usm_$usm.mp4",
    variable=:Ra_PAR_f, tiled=true
)

plot_3D_interception(
    df_gp_usm, series, meteo_growth, usm, (x_min, y_min, x_max, y_max);
    colorrange=(0, 0.8),
    output_path="2-results/aPAR_J_usm_$usm.mp4",
    variable=:Ra_PAR_q
)

# Scene incident PAR from the meteo (quantity):
# xmin, ymin, xmax, ymax = scene.scene_xy_bounds

scene_area = (x_max - x_min) * (y_max - y_min)
Ri_PAR_q_from_meteo = meteo_growth.Ri_PAR_f .* meteo_growth.duration .* scene_area

# Compute the fraction of absorbed PAR (faPAR) over time:
aPAR_growth_scene = [sum(values(series[i].budget.absorbed_energy.total.par)) for i in 1:length(series)]
iPAR_growth_scene = [sum(values(series[i].budget.incident_energy.initial.par)) for i in 1:length(series)]

all(isapprox.(Ri_PAR_q_from_meteo, iPAR_growth_scene; rtol=0.002)) # Check that the incident PAR from the meteo matches the incident PAR computed by ArchimedLight

# aPAR_growth_incident = [meteo_growth[i].Ri_PAR_f * meteo_growth[i].duration for i in 1:length(series)]# sum(values(series[1].budget.incident_energy.total.par))
faPAR = aPAR_growth_scene ./ Ri_PAR_q_from_meteo
fig_fapar = Figure()
ax_fapar = Axis(fig_fapar[1, 1], title="Fraction of absorbed PAR (faPAR) over time (usm 14)", xlabel="Days after sowing", ylabel="faPAR")
lines!(ax_fapar, 1:length(series), faPAR, color=:black, linewidth=2, label="faPAR")
save("2-results/faPAR_over_time.png", fig_fapar, px_per_unit=3.0)

apar_maize_plants = light_metric_values(
    scene,
    series,
    :absorbed_par_energy;
    species="maize",
    sink=DataFrame
)

apar_sorghum_plants = light_metric_values(
    scene,
    series,
    :absorbed_par_energy;
    species="sorghum",
    sink=DataFrame
)

apar_ground = light_metric_values(
    scene,
    series,
    :absorbed_par_energy;
    species="pavement",
    sink=DataFrame
)

apar_plants = vcat(apar_maize_plants, apar_sorghum_plants)
df_apar_all = vcat(apar_plants, apar_ground)

df_apar_grouped = groupby(df_apar_all, [:group, :object_id, :step_number])
df_apar_combined = combine(df_apar_grouped, :value => sum => :apar_sum)
sort!(df_apar_combined, [:step_number, :group, :object_id])
df_meteo = DataFrame(meteo_growth)
df_meteo.step_number = 1:length(meteo_growth)
joined_df = leftjoin(df_apar_combined, df_meteo, on=:step_number)
joined_df.fapar = joined_df.apar_sum ./ (joined_df.Ri_PAR_f .* joined_df.duration .* scene_area)
# Check that dataframe values match the aPAR growth computed from the scene:
all(combine(groupby(df_apar_combined, :step_number), :apar_sum => sum => :apar_total).apar_total .≈ aPAR_growth_scene)

p = data(joined_df) *
    mapping(:step_number, :fapar, color=:object_id, layout=:group, group=:object_id) *
    visual(Lines)
f = draw(p)
save("2-results/faPAR_over_time_per_object.png", f, px_per_unit=3.0)

df_per_species = combine(
    groupby(joined_df, [:step_number, :group]),
    :apar_sum => sum => :apar_sum_species,
    [:Ri_PAR_f, :duration] => ((iPAR, d) -> first(iPAR) .* first(d) .* scene_area) => :iPAR,
)
df_per_species.faPAR = df_per_species.apar_sum_species ./ df_per_species.iPAR

p_species =
    data(df_per_species) *
    mapping(:step_number, :faPAR, color=:group) *
    visual(Lines)
f_species = draw(p_species)
save("2-results/faPAR_over_time_per_species.png", f_species, px_per_unit=3.0)

apar_plants = [sum(
    value for (node_id, value) in series[i].budget.absorbed_energy.total.par
              if ArchimedLight._scene_group(scene, node_id, "") == "plant"
) for i in 1:length(series)]

unique([ArchimedLight._scene_group(scene, node_id, "") for (node_id, value) in series[80].budget.absorbed_energy.total.par])

[sum(
    value for (node_id, value) in series[i].budget.absorbed_energy.total.par
              if ArchimedLight._scene_group(scene, node_id, "") == ""
) for i in 1:length(series)]

apar_ground = [sum(
    value for (node_id, value) in series[i].budget.absorbed_energy.total.par
              if ArchimedLight._scene_group(scene, node_id, "") == "pavement"
) for i in 1:length(series)]

faPAR_plants = apar_plants ./ Ri_PAR_q_from_meteo
faPAR_ground = apar_ground ./ Ri_PAR_q_from_meteo
fig_fapar = Figure()
ax_fapar = Axis(fig_fapar[1, 1], title="Fraction of absorbed PAR (faPAR) over time (usm 14)", xlabel="Days after sowing", ylabel="faPAR")
lines!(ax_fapar, 1:length(series), faPAR_plants, color=:black, linewidth=2, label="plants")
lines!(ax_fapar, 1:length(series), faPAR_ground, color=:gray, linewidth=2, label="ground")
lines!(ax_fapar, 1:length(series), faPAR, color=:black, linewidth=4, label="total", linestyle=:dash)
lines!(ax_fapar, 1:length(series), faPAR_plants .+ faPAR_ground, color=:red, linewidth=4, label="total (sum)", linestyle=:dash)
Legend(fig_fapar[1, 2], ax_fapar)
fig_fapar
save("2-results/faPAR_over_time_plants_ground.png", fig_fapar, px_per_unit=3.0)

# Plotting the plot at maturity with tiling:
day_index_tiled = 70
scene_day_indexed = df_gp_usm[day_index_tiled, 4]
scene_tiled = ArchimedLight.tile_light_geometry(scene_day_indexed, series[day_index_tiled]; nx=10, ny=10)
f_tiled, ax_tiled, p_tiled = ArchimedLight.lightplot(scene_tiled, series[day_index_tiled]; color=:Ra_PAR_f, colormap=:thermal)
Colorbar(f_tiled[1, 2], p_tiled, label="aPAR (W m⁻²)")
f_tiled
save("2-results/light_usm14_70_days_after_sowing_tiled.png", f_tiled)
# fig, ax, l = ArchimedLight.lightplot(series; color=:incident_par_flux, colormap=:thermal, timestep=1)
# record(fig, "2-results/light.mp4", 2:length(series), framerate=1) do frame
#     Makie.update!(p, timestep=frame)
#     ax.title = "Absorbed PAR (W m⁻²) $(meteo[frame].date)"
# end


## Plotting the 3D scene for usms 1,2,3,4,5,6,10,18,20,22,26 on 2018-09-19 with 10x10 tilling: ##
day_static_plot_3D = Date(2018, 9, 19)
usms_3D_static = [1, 2, 3, 4, 5, 6, 10, 18, 20, 22, 26]
algo = "Beer"
df_scene_day_static = subset(
    DataFrames.transform(groupby(df_gp, [:usm, :algo]), :date => (x -> 1:length(x)) => :date_index),
    :date => (x -> x .== day_static_plot_3D),
    :usm => ByRow(x -> x in usms_3D_static),
    :algo => (x -> x .== algo),
    view=true
)

# Make the simulations:
meteo_index = findfirst(==(day_static_plot_3D), meteo.date)
isnothing(meteo_index) && error("No meteorology found for $day_static_plot_3D")
meteo_day = meteo[meteo_index, :]

series_static = Vector{ArchimedLight.LightStepResult}(undef, nrow(df_scene_day_static))
for (i, r) in enumerate(eachrow(df_scene_day_static))
    usm = r.usm
    date = r.date
    date_index = r.date_index
    # x_min, y_min, x_max, y_max = domains[domains.usms .== usm, 2:end][1, :]

    scene = r.x1
    sim = LightSimulation(r.x1, models; options=options)
    light = run_light(sim, meteo_day)
    series_static[i] = light
end

df_scene_day_static.archimed_light_result = series_static

# Making the plots:
for r in eachrow(df_scene_day_static)
    usm = r.usm
    date = r.date
    date_index = r.date_index
    scene_tiled = ArchimedLight.tile_light_geometry(r.x1, r.archimed_light_result; nx=10, ny=10)
    f_tiled, ax_tiled, p_tiled = ArchimedLight.lightplot(scene_tiled, r.archimed_light_result; color=:Ra_PAR_f, colormap=:thermal)
    Colorbar(f_tiled[1, 2], p_tiled, label="aPAR (W m⁻²)")
    save("2-results/static_light_result_$(usm)_$(day_static_plot_3D).png", f_tiled)
end


# Making one figure from all results:
metric = :Ra_PAR_f

# One common colour scale, so colours are comparable across USMs.
finite_values = Float64[
    value
    for result in df_scene_day_static.archimed_light_result
    for value in values(ArchimedLight.light_metric_values(result, metric))
    if isfinite(value)
]
shared_colorrange = (0.0, maximum(finite_values))

ncols = 4
nrows = cld(nrow(df_scene_day_static), ncols)

fig = Figure(size=(1800, 1200))
panel_plots = Any[]

for (i, r) in enumerate(eachrow(df_scene_day_static))
    row = cld(i, ncols)
    col = mod1(i, ncols)

    ax = Axis3(
        fig[row, col];
        title="USM $(r.usm)",
        aspect=:data,
        viewmode=:fit,
        azimuth=(-π / 4),
        elevation=π / 6,
        protrusions=0,
    )

    tiled_geometry = ArchimedLight.tile_light_geometry(
        r.x1,
        r.archimed_light_result;
        nx=10,
        ny=10,
    )

    p = ArchimedLight.lightplot!(
        ax,
        tiled_geometry,
        r.archimed_light_result;
        color=metric,
        colormap=:thermal,
        colorrange=shared_colorrange,
    )
    push!(panel_plots, p)

    hidedecorations!(ax)
    hidespines!(ax)
end

Label(
    fig[0, 1:ncols],
    "Absorbed PAR — $day_static_plot_3D";
    fontsize=24,
)

Colorbar(
    fig[1:nrows, ncols+1],
    first(panel_plots);
    label="aPAR (W m⁻²)",
)

save(
    "2-results/static_light_results_all_usms_$(day_static_plot_3D).png",
    fig;
    px_per_unit=2,
)

fig


