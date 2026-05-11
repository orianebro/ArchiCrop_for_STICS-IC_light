# Objective: Run stics simulations of sole crops and their equivalent intercropping systems, with Beer and 2.5D formalisms, to compare with 3D simulations from ArchiCrop+Caribu.
# Output from this script are (inputs for ArchiCrop+Caribu for each simulation):
# 1. Dynamic outputs from STICS of LAI (laimax, laisen(n)), crop height (hauteur), thermal time corrected by stresses (somupvtsem), intercepted radiation (raint), incoming/transmitted radiation (trg(n) from each crop),
#  fraction of absorbed PAR (fapar), phenology (ilevs, iamfs, ilaxs), actual density (densite)
# 2. Inputs from STICS (from the meteo file) incoming radiation: trg(n) (this is for Caribu)
# 3. Parameters:
#   1. from tec file: interrow distance (plant-plant / species-species), row orientation, nrows per strip
#   2. from plant file: leaf lifespan (lifespanF) and ratio of lifespan between juvenile stage and exponential phase (ratiodurvieI)

library(SticsRPacks)
