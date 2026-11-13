module SticsWeather

using CSV, DataFrames, Dates, PlantMeteo
export read_stics_weather, weather_site_for_dates, weather_paths

"""Read STICS daily climate: MJ/m²/day→W/m², hPa→kPa, Rh in [0,1]."""
function read_stics_weather(paths; latitude)
    columns = [:station,:year,:month,:day,:dayofyear,:Tmin,:Tmax,
        :SW_MJ_m2_day,:etp,:Precipitations,:Wind,:e_hPa,:CO2]
    isempty(paths) && throw(ArgumentError("At least one STICS climate file is required"))
    table = vcat([CSV.read(path,DataFrame;header=columns,delim=' ',ignorerepeated=true)
        for path in paths]...)
    sort!(table,[:year,:month,:day])
    dates = [Date(row.year,row.month,row.day) for row in eachrow(table)]
    allunique(dates) || error("Duplicate dates in STICS climate inputs")
    for row in eachrow(table)
        values = (row.Tmin,row.Tmax,row.SW_MJ_m2_day,row.Wind,row.e_hPa,row.CO2)
        all(isfinite,values) || error("Nonfinite STICS climate observation")
        -100 <= row.Tmin <= row.Tmax <= 80 || error("Invalid STICS daily temperatures")
        row.SW_MJ_m2_day>=0 && row.Wind>=0 && row.e_hPa>=0 && row.CO2>0 ||
            error("Invalid STICS radiation, wind, vapour pressure or CO₂")
    end
    return Weather([let temperature=(row.Tmin+row.Tmax)/2,
            shortwave=row.SW_MJ_m2_day*1e6/86400, vapour=row.e_hPa/10
        (date=Date(row.year,row.month,row.day),hour_start=Time(0),duration=86400.0,
            latitude=Float64(latitude),Ri_SW_f=shortwave,Ri_PAR_f=.48*shortwave,
            T=temperature,Wind=row.Wind,Rh=PlantMeteo.rh_from_e(vapour,temperature),
            e=vapour,Cₐ=row.CO2,Precipitations=row.Precipitations)
    end for row in eachrow(table)])
end

function weather_paths(root)
    Dict(:Ntarla=>([joinpath(root,"ntarla_corr.2018")],12.58),
        :Auzeville=>([joinpath(root,"auzevilj.2006"),joinpath(root,"auzevilj.2007")],43.0))
end

function weather_site_for_dates(dates, available_dates)
    isempty(dates) && error("No scene dates supplied")
    candidates = [site for (site,covered) in available_dates if all(d->d in covered,dates)]
    length(candidates)==1 || error("Expected one climate site covering $(minimum(dates))–$(maximum(dates)); found $candidates")
    return only(candidates)
end

end
