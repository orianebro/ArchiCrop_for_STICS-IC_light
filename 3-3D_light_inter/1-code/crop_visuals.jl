module CropVisuals

using PlantGeom, GLMakie, ArchimedLight, PlantMeteo
using FileIO, MultiScaleTreeGraph, GeometryBasics, CSV, DataFrames, Dates
using SHA, Serialization
include(joinpath(@__DIR__, "stics_weather.jl"))
using .SticsWeather: read_stics_weather, weather_paths, weather_site_for_dates

export growth_video, illuminated_figure, generate_oriane_visuals,
    periodic_scene, periodic_scene_window, compact_scene_metadata,
    fresh_scene_index, fresh_scene_folder, fresh_scene,
    compact_scene_index, basal_root

const ROOT = normpath(joinpath(@__DIR__, ".."))
const OUTPUT = joinpath(ROOT, "2-results", "oriane")
const FRESH_ASSETS = joinpath(ROOT, "0-data", "full_archicrop_code_shape2_2026-11-10")
const COMPACT_ASSETS = FRESH_ASSETS
const GREEN = Makie.to_color("#258b43")
const YELLOW = Makie.to_color("#e8c547")
const SOIL = Makie.to_color("#c9b99b")

# Adapted from the existing read_plant / growth / static-panel blocks.
# OBJ coordinates are cm; PlantGeom and ArchimedLight use metres.
function read_crop(obj_path, mtg_path)
    obj = load(obj_path)
    parts = split_mesh(GeometryBasics.Mesh(obj))
    isempty(parts) && return nothing # maize before emergence
    meshes = Dict(split(name, "_")[end] =>
        GeometryBasics.Mesh(0.01 .* coordinates(part), faces(part))
        for (name, part) in zip(obj[:object], parts))
    mtg = read_mtg(mtg_path, NodeMTG)
    # Snapshot the original nodes before adding leaf sections.
    nodes = MultiScaleTreeGraph.Node[]
    traverse!(mtg) do node
        push!(nodes, node)
    end
    for node in nodes
        isnothing(node[:Id]) && continue
        key = string(node[:Id])
        sen_key = string(node[:Id] + 10_000_000)
        if symbol(node) == :Stem
            haskey(meshes, key) || continue
            node[:geometry] = PlantGeom.Geometry(ref_mesh=RefMesh(key, meshes[key]))
            node[:state] = node[:is_green] == 0 ? "senescent" : "active"
        elseif symbol(node) == :Leaf
            # Stems are represented once. Fully senescent leaves need no active mesh.
            for (section, meshkey, state) in ((1, key, "active"), (2, sen_key, "senescent"))
                haskey(meshes, meshkey) || continue
                MultiScaleTreeGraph.addchild!(node,
                    NodeMTG("/", "LeafSection", section, MultiScaleTreeGraph.scale(node) + 1),
                    Dict(:geometry => PlantGeom.Geometry(ref_mesh=RefMesh(meshkey, meshes[meshkey])),
                        :state => state))
            end
        end
    end
    return mtg
end

function crop_scene(rows)
    folders = unique(rows.scene_folder)
    length(folders) == 1 || error("crop_scene expects one USM/date compact scene")
    return periodic_scene(only(folders))
end

"""
    periodic_scene(folder)

Import a regenerated periodic scene from its compact templates and placements.
All placements are in metres; each OBJ template is already centred on its root
and remains in centimetres, as required by `read_crop`. The complete domain and
all plants are loaded from the scene placement CSV.
"""
periodic_scene(folder::AbstractString) = _periodic_scene(folder, nothing, 0.0)

"""
    periodic_scene_window(folder; length=nothing, margin=0.8)

By default load the complete cell. A supplied length selects a longitudinal
excerpt for design inspection. This is a display crop of
the full periodic scene, not a new periodic simulation domain. Neighbouring
plants within `margin` are kept so overhanging leaves reach the visible window.
Use `periodic_scene(folder)` for a complete numerical scene.
"""
function periodic_scene_window(folder::AbstractString; length=nothing, margin=0.8)
    isnothing(length) && return periodic_scene(folder)
    length > 0 || throw(ArgumentError("display length must be positive"))
    margin >= 0 || throw(ArgumentError("display margin must be nonnegative"))
    return _periodic_scene(folder, Float64(length), Float64(margin))
end

function geometry_present(row)
    :geometry_present in propertynames(row) || return true
    value = row.geometry_present
    value isa Bool && return value
    ismissing(value) && error("Missing geometry_present flag for plant $(row.plant_id)")
    text = lowercase(string(value))
    text in ("true","1") && return true
    text in ("false","0") && return false
    error("Invalid geometry_present flag $value")
end

"""Read compact scene metadata without inferring density from canopy presence.

Domain/placement CSVs are in metres; the historical domains.csv table is in cm.
Logical planting rows with geometry_present=false remain in the metadata and
are deliberately omitted from the aerial mesh. Their templates may be absent.
"""
function compact_scene_metadata(folder::AbstractString)
    box = only(eachrow(CSV.read(joinpath(folder, "domain.csv"), DataFrame)))
    bounds = Float64[box.xmin, box.ymin, box.xmax, box.ymax]
    all(isfinite,bounds) && bounds[3]>bounds[1] && bounds[4]>bounds[2] ||
        error("Invalid metre domain in $folder")
    orientation = string(box.orientation)
    orientation in ("N-S", "E-W") || error("Unknown scene orientation $orientation")
    placements = CSV.read(joinpath(folder, "placements.csv"), DataFrame)
    required = [:plant_id,:species,:template_id,:x_m,:y_m,:z_m]
    all(name->name in propertynames(placements),required) || error("Incomplete placements in $folder")
    ids = placements.plant_id
    length(unique(ids)) == length(ids) || error("Duplicate plant ids in $folder")
    presence = [geometry_present(row) for row in eachrow(placements)]
    for row in eachrow(placements)
        all(isfinite,(row.x_m,row.y_m,row.z_m)) || error("Nonfinite logical root in $folder")
        bounds[1]-1e-9 <= row.x_m <= bounds[3]+1e-9 &&
            bounds[2]-1e-9 <= row.y_m <= bounds[4]+1e-9 || error("Logical root outside metre domain")
    end
    template_table = CSV.read(joinpath(folder,"templates.csv"),DataFrame)
    all(name->name in propertynames(template_table),[:template_id,:species,:obj,:mtg]) ||
        error("Incomplete templates table in $folder")
    length(unique(string.(template_table.template_id))) == nrow(template_table) ||
        error("Duplicate template id in $folder")
    visible = placements[presence,:]
    return (;folder=abspath(folder),bounds=Tuple(bounds),orientation,placements,
        visible_placements=visible,template_table,logical_plants=nrow(placements),
        geometry_plants=nrow(visible),absent_geometry_plants=nrow(placements)-nrow(visible))
end

"""Actual root anchor from the basal main-axis stem, without repositioning it."""
function basal_root(plant)
    found = Ref{Any}(nothing)
    traverse!(plant) do node
        symbol(node) == :Stem && node[:Id] == 3 && PlantGeom.has_geometry(node) || return
        points = coordinates(PlantGeom.geometry_to_mesh(node[:geometry]))
        isempty(points) && return
        zmin = minimum(point[3] for point in points)
        xy = Set((Float64(point[1]),Float64(point[2])) for point in points if abs(point[3]-zmin)<=1e-9)
        found[] = Point3d(sum(p[1] for p in xy)/length(xy),sum(p[2] for p in xy)/length(xy),zmin)
    end
    isnothing(found[]) && error("Nonempty plant has no basal main-axis stem vid_3")
    return found[]
end

function _periodic_scene(folder, display_length, margin)
    metadata = compact_scene_metadata(folder)
    bounds = collect(metadata.bounds)
    orientation = metadata.orientation
    along = orientation == "N-S" ? :x_m : :y_m
    longitudinal_max = orientation == "N-S" ? bounds[3] : bounds[4]
    placements = copy(metadata.visible_placements)
    if !isnothing(display_length)
        display_length <= longitudinal_max || error("Display window exceeds complete scene")
        filter!(r -> -margin <= r[along] <= display_length + margin, placements)
        bounds[orientation == "N-S" ? 3 : 4] = display_length
    end
    templates = Dict{String,Any}()
    species = Dict{String,String}()
    needed = Set(string.(placements.template_id))
    for row in eachrow(metadata.template_table)
        key = string(row.template_id)
        key in needed || continue
        plant = read_crop(joinpath(folder, row.obj), joinpath(folder, row.mtg))
        isnothing(plant) && error("geometry_present=true references empty template $key in $folder")
        string(plant.species) == string(row.species) || error("Template species mismatch for $key")
        maximum(abs,basal_root(plant)) <= 1e-6 || error("Fresh compact template $key is not rooted at zero")
        templates[key] = plant
        species[key] = string(row.species)
    end
    issubset(needed,Set(keys(templates))) || error("A visible plant references an absent template in $folder")
    PlantGeom.make_scene(domain=Tuple(bounds)) do scene
        scene.mtg[:source_compact_scene] = abspath(folder)
        scene.mtg[:source_logical_plant_count] = metadata.logical_plants
        scene.mtg[:source_geometry_plant_count] = metadata.geometry_plants
        scene.mtg[:source_absent_geometry_plant_count] = metadata.absent_geometry_plants
        scene.mtg[:imported_geometry_plant_count] = nrow(placements)
        for row in eachrow(placements)
            key = string(row.template_id)
            string(row.species) == species[key] || error("Plant/template species mismatch for $(row.plant_id)")
            add_plant!(scene, templates[key]; group=species[key], id=row.plant_id,
                at=(row.x_m, row.y_m, row.z_m))
        end
        add_ground!(scene; nx=20, ny=20, group="pavement", type="Cobblestone")
    end
end

fresh_scene_folder(usm,day;algo="2.5D",root=FRESH_ASSETS) =
    joinpath(root,"usm_$(usm)_$(algo)","scenes",string(day))

"""Assemble only newly grown daily templates and their explicit logical roots."""
fresh_scene(usm,day;algo="2.5D",root=FRESH_ASSETS) =
    periodic_scene(fresh_scene_folder(usm,day;algo,root))

"""Index completed compact daily exports, using full dates and no old-asset fallback."""
function fresh_scene_index(;usms=nothing,algorithms=["2.5D","Beer"],dates=nothing,root=FRESH_ASSETS)
    isdir(root) || error("Fresh export root does not exist: $root")
    requested = isnothing(usms) ? nothing : Set(Int.(usms))
    wanted_dates = isnothing(dates) ? nothing : Set(Date.(dates))
    indexed = DataFrame(usm=Int[],algorithm=String[],date=Date[],folder=String[])
    for name in readdir(root)
        matched = match(r"^usm_(\d+)_(Beer|2\.5D)$",name)
        isnothing(matched) && continue
        usm,algo = parse(Int,matched[1]),String(matched[2])
        isnothing(requested) || usm in requested || continue
        algo in algorithms || continue
        isfile(joinpath(root,name,"index.json")) || error("Fresh case is not complete: $(joinpath(root,name))")
        scenes = joinpath(root,name,"scenes")
        isdir(scenes) || error("Fresh case has no completed scenes directory: $scenes")
        for day_name in readdir(scenes)
            isnothing(match(r"^\d{4}-\d{2}-\d{2}$",day_name)) && continue
            day = Date(day_name)
            isnothing(wanted_dates) || day in wanted_dates || continue
            folder = joinpath(scenes,day_name)
            all(isfile(joinpath(folder,file)) for file in ("domain.csv","templates.csv","placements.csv")) ||
                error("Incomplete fresh scene: $folder")
            push!(indexed,(usm,algo,day,folder))
        end
    end
    if !isnothing(requested)
        for usm in requested,algo in algorithms
            any((indexed.usm .== usm) .& (indexed.algorithm .== algo)) ||
                error("No complete fresh scenes for USM $usm / $algo")
        end
    end
    sort!(indexed,[:usm,:algorithm,:date])
    return indexed
end

"""Index compact scenes for the visualisation and simulation functions."""
function compact_scene_index(usms;algo="2.5D",day=nothing,source=FRESH_ASSETS)
    indexed = fresh_scene_index(;usms,algorithms=[algo],dates=isnothing(day) ? nothing : [day],root=source)
    return DataFrame(usm=indexed.usm,date=indexed.date,scene_folder=indexed.folder)
end

light_options() = LightOptions(turtle_sectors=46, pixel_size=0.01, toricity=true,
    scattering=true, cache_radiation=false, all_in_turtle=true,
    radiation_timestep_minutes=10, nir_interception=false, scene_rotation_deg=90.0)
light_models() = models_for("*" => ("Stem" => translucent(par=0.15, nir=0.90),
    "LeafSection" => translucent(par=0.15, nir=0.90)),
    "pavement" => ("Cobblestone" => translucent(par=0.12, nir=0.60),))

function weather_day(day, options)
    configurations = weather_paths(joinpath(ROOT, "0-data"))
    available = Dict(site => read_stics_weather(paths;latitude)
        for (site,(paths,latitude)) in configurations)
    site = weather_site_for_dates([day],Dict(site=>Set(row.date for row in weather)
        for (site,weather) in available))
    selected = Weather([NamedTuple(row) for row in available[site] if row.date==day])
    return only(prepare_meteo(selected,options))
end

# Repeat the periodic unit to cover the same physical field window in each panel.
# Geometry repetition is for display; interception is solved on the original toric unit.
function field_geometry(scene, payload; field_width=5.5)
    xmin, ymin, xmax, ymax = scene.scene_xy_bounds
    dx, dy = xmax - xmin, ymax - ymin
    nx, ny = ceil(Int, field_width / dx), ceil(Int, field_width / dy)
    geometry = tile_light_geometry(scene, payload; nx, ny, centered=false)
    cx, cy = xmin + nx * dx / 2, ymin + ny * dy / 2
    points = [GeometryBasics.Point3d(p[1] - cx, p[2] - cy, p[3]) for p in geometry.vertices]
    return ArchimedLight.LightRenderGeometry(points, geometry.faces, geometry.face2node)
end

function growth_mesh(scene; field_width=5.5)
    geometry = field_geometry(scene,
        light_render_geometry(scene, light_models(), light_options()); field_width)
    colors = Dict{Int,typeof(GREEN)}()
    traverse!(scene.mtg) do node
        PlantGeom.has_geometry(node) || return
        colors[MultiScaleTreeGraph.node_id(node)] = symbol(node) in (:Stem, :LeafSection) ?
            (node[:state] == "senescent" ? YELLOW : GREEN) : SOIL
    end
    per_face = [colors[id] for id in geometry.face2node]
    base = GeometryBasics.Mesh(geometry.vertices, geometry.faces)
    return GeometryBasics.mesh(base; color=GeometryBasics.per_face(per_face, geometry.faces))
end

function crop_axis(position; title, field_width=5.5, height=3.5)
    half = field_width / 2
    ax = Axis3(position; title, aspect=:data, viewmode=:fitzoom,
        azimuth=-π / 4, elevation=π / 6, protrusions=(5, 5, 5, 75),
        limits=((-half, half), (-half, half), (0, height)))
    hidedecorations!(ax)
    hidespines!(ax)
    return ax
end

"""Render all available dates in chronological order, one day per frame (no interpolation)."""
function growth_video(; usm=54, algo="2.5D", framerate=12, field_width=5.5,
        output_dir=OUTPUT, dates=nothing)
    mkpath(output_dir)
    rows = compact_scene_index([usm]; algo)
    isnothing(dates) || filter!(r -> r.date in dates, rows)
    days = sort(unique(rows.date))
    isempty(days) && error("No video dates selected")
    first_scene = crop_scene(filter(r -> r.date == first(days), rows))
    fig = Figure(size=(1400, 1000), fontsize=22, backgroundcolor=:white)
    Label(fig[0, 1], "USM $usm · $algo · croissance ArchiCrop"; fontsize=28, tellwidth=false)
    ax = crop_axis(fig[1, 1]; title=string(first(days)), field_width)
    mesh_data = Observable(growth_mesh(first_scene; field_width))
    mesh!(ax, mesh_data; shading=NoShading)
    Legend(fig[2, 1], [PolyElement(color=GREEN), PolyElement(color=YELLOW), PolyElement(color=SOIL)],
        ["Green tissue", "Senescent tissue", "Soil"]; orientation=:horizontal, framevisible=false)
    Label(fig[3, 1], "$(field_width) × $(field_width) m periodic field · one day per frame"; fontsize=18, tellwidth=false)
    path = joinpath(output_dir, "growth_usm_$(usm)_$(algo).mp4")
    record(fig, path; framerate, px_per_unit=1, scalefactor=1, profile="high",
            pixel_format="yuv420p", compression=18) do stream
        for i in eachindex(days)
            if i > 1
                scene = crop_scene(filter(r -> r.date == days[i], rows))
                mesh_data[] = growth_mesh(scene; field_width)
            end
            ax.title = string(days[i])
            recordframe!(stream)
            if days[i] in (first(days), Date(2007, 6, 25), last(days))
                # Capture the recording screen directly. save(fig) would resize the
                # live GL screen on a Retina display and change subsequent frames.
                FileIO.save(joinpath(output_dir, "growth_usm_$(usm)_$(algo)_$(days[i]).png"),
                    Makie.colorbuffer(stream.screen))
            end
            (i == 1 || i % 30 == 0 || i == length(days)) && @info "Growth video" frame=i date=days[i] total=length(days)
        end
    end
    CSV.write(joinpath(output_dir, "growth_usm_$(usm)_$(algo)_frames.csv"),
        DataFrame(frame=eachindex(days), date=days, time_seconds=(0:length(days)-1) ./ framerate))
    return path
end

function fingerprint(rows, day)
    io = IOBuffer()
    for path in [@__FILE__, joinpath(ROOT, "Manifest.toml"),
            joinpath(@__DIR__, "stics_weather.jl"),
            joinpath(ROOT, "0-data", year(day)==2018 ? "ntarla_corr.2018" : "auzevilj.$(year(day))")]
        write(io, read(path))
    end
    for folder in unique(rows.scene_folder)
        for file in ("domain.csv", "placements.csv", "templates.csv")
            write(io, read(joinpath(folder, file)))
        end
        templates = CSV.read(joinpath(folder, "templates.csv"), DataFrame)
        for row in eachrow(templates), column in (:obj, :mtg)
            write(io, read(joinpath(folder, row[column])))
        end
    end
    bytes2hex(sha256(take!(io)))
end

"""Four daily-mean absorbed-PAR panels with one shared scale, including scattering."""
function illuminated_figure(; usms=[48, 52, 54, 61], day=Date(2007, 6, 25),
        algo="2.5D", field_width=5.5, output_dir=OUTPUT, force=false)
    mkpath(output_dir)
    rows = compact_scene_index(usms; algo, day)
    options, models = light_options(), light_models()
    meteo = weather_day(day, options)
    scenes, results = Any[], ArchimedLight.LightStepResult[]
    for usm in usms
        selected = filter(r -> r.usm == usm, rows)
        scene = crop_scene(selected)
        key = fingerprint(selected, day)
        cache = joinpath(output_dir, "light_usm_$(usm)_$(algo)_$(day).jls")
        stored = isfile(cache) && !force ? deserialize(cache) : nothing
        result = if !isnothing(stored) && stored.key == key
            @info "Using cached daily light result" usm day
            stored.result
        else
            @info "Simulating daily light interception" usm day
            light = run_light(LightSimulation(scene, models; options), meteo)
            serialize(cache, (; key, result=light))
            light
        end
        metrics = light_metric_values(result, :Ra_PAR_f)
        ids = sort(collect(keys(metrics)))
        CSV.write(joinpath(output_dir, "light_usm_$(usm)_$(algo)_$(day)_components.csv"),
            DataFrame(node_id=ids, absorbed_PAR_W_m2=[metrics[id] for id in ids]))
        push!(scenes, scene)
        push!(results, result)
    end
    finite = [v for result in results for v in values(light_metric_values(result, :Ra_PAR_f)) if isfinite(v)]
    isempty(finite) && error("No finite absorbed-PAR values")
    colorrange = (0.0, maximum(finite))
    fig = Figure(size=(1800, 1500), fontsize=24, backgroundcolor=:white)
    ncols = 2
    nrows = cld(length(usms), ncols)
    labels = Dict(48 => "14 wheat / 2 maize rows · N–S", 52 => "6 wheat / 6 maize rows · N–S",
        54 => "6 wheat / 2 maize rows · N–S", 61 => "6 wheat / 6 maize rows · E–W")
    for (i, usm) in enumerate(usms)
        ax = crop_axis(fig[cld(i, ncols), mod1(i, ncols)];
            title="$(Char('a' + i - 1))   USM $usm\n$(get(labels, usm, ""))", field_width)
        geometry = field_geometry(scenes[i], results[i]; field_width)
        ArchimedLight.lightplot!(ax, geometry, results[i]; color=:Ra_PAR_f,
            colormap=:thermal, colorrange, shading=NoShading)
    end
    Label(fig[0, 1:ncols], "Daily mean absorbed PAR · $day · $algo"; fontsize=32)
    Colorbar(fig[1:nrows, ncols + 1]; colormap=:thermal, colorrange,
        label="Absorbed PAR (W m⁻² of organ surface)", width=26)
    Label(fig[nrows + 1, 1:ncols],
        "Auzeville · $(field_width) × $(field_width) m periodic field in each panel · common colour scale"; fontsize=21)
    path = joinpath(output_dir, "illuminated_usms_$(join(usms, "_"))_$(algo)_$(day).png")
    save(path, fig; px_per_unit=2)
    open(joinpath(output_dir, "visualization_notes.txt"), "w") do io
        println(io, "Geometry algorithm: $algo; date: $day; USMs: $usms")
        println(io, "Daily mean over 86400 s, including scattering; metric Ra_PAR_f; range $colorrange W m^-2.")
        println(io, "Weather: auzevilj.$(year(day)); latitude 43.0; MJ m^-2 day^-1 converted to W m^-2 with 1e6/86400.")
        println(io, "Incident daily mean PAR: $(meteo.Ri_PAR_f) W m^-2; PAR fraction of shortwave: 0.48.")
        println(io, "Stems are attached once; green and senescent leaf sections retain their separate OBJ meshes.")
        println(io, "Preserved optical models: translucent PAR coefficient 0.15 for stems and both leaf states, 0.12 for soil; age colours do not imply different optics.")
        println(io, "Tiling is visual only; original periodic domain, 0.01 m pixels, 46 sky sectors, 10 min radiation integration.")
        println(io, "Legacy integrated fAPAR CSVs are not used or overwritten. Cache hashes include inputs, script and Manifest.")
        println(io, "Julia $(VERSION); ArchimedLight $(pkgversion(ArchimedLight)); GLMakie $(pkgversion(GLMakie)).")
    end
    return path
end

function generate_oriane_visuals(; algo="2.5D", video=true, figure=true, output_dir=OUTPUT)
    image = figure ? illuminated_figure(; algo, output_dir) : nothing
    movie = video ? growth_video(; algo, output_dir) : nothing
    return (; figure=image, video=movie)
end

end # module
