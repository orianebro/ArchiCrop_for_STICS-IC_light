# ArchiCrop output visualisation

This repository uses the mtg and obj files output by the ArchiCrop model to generate videos of the simulated plant growth.

## Run

Install Julia, and open it, then activate the environment from Julia's REPL:

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

Then you can just run the script to generate the videos:

```julia
include("generate_video.jl")
```
