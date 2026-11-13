"""Write current STICS/ArchimedLight comparison figures and tables."""
from pathlib import Path
import argparse
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from matplotlib.lines import Line2D
import pandas as pd
from light_pipeline_analysis import compare_light_results, summarize_groups, whole_canopy, REPO, DEFAULT_RESULTS, STICS, SCENES


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results",type=Path,default=DEFAULT_RESULTS)
    parser.add_argument("--stics",type=Path,default=STICS)
    parser.add_argument("--scenes",type=Path,default=SCENES)
    parser.add_argument("--output",type=Path,default=REPO/"results")
    args=parser.parse_args()
    frame=compare_light_results(args.results,args.stics,args.scenes)
    out=args.output;out.mkdir(parents=True,exist_ok=True)
    figures=out/"figures";figures.mkdir(exist_ok=True)
    frame.to_csv(out/"daily_comparisons.csv",index=False)
    whole=whole_canopy(frame)
    whole.to_csv(out/"whole_canopy_daily_comparisons.csv",index=False)
    summarize_groups(frame,["usm","algorithm","species"]).to_csv(out/"species_case_metrics.csv",index=False)
    summarize_groups(whole,["usm","algorithm"]).to_csv(out/"case_metrics.csv",index=False)
    summarize_groups(frame,["site","design","species","algorithm"]).to_csv(out/"stratified_metrics.csv",index=False)
    frame.groupby(["usm","algorithm"]).agg(observed_dates=("date","nunique"),first_date=("date","min"),last_date=("date","max")).reset_index().to_csv(out/"case_calendar_coverage.csv",index=False)
    colors={"maize":"#2469ad","sorghum":"#bc8037","wheat":"#248543"}
    for (usm,algo),case in frame.groupby(["usm","algorithm"]):
        fig,axes=plt.subplots(2,1,figsize=(11.8,6.7),sharex=True)
        for species,rows in case.groupby("species"):
            for ax,a,b in ((axes[0],"fapar_stics","fapar_archimed"),(axes[1],"stics_apar_W_m2","archimed_apar_W_m2")):
                ax.plot(rows.date,rows[a],color=colors[species],ls="--")
                ax.plot(rows.date,rows[b],color=colors[species])
        for ax in axes:
            ax.grid(alpha=.16);ax.set_ylim(bottom=0)
            loc=mdates.AutoDateLocator(minticks=3,maxticks=6)
            ax.xaxis.set_major_locator(loc);ax.xaxis.set_major_formatter(mdates.ConciseDateFormatter(loc))
        axes[0].set_ylim(0, max(1,case[["fapar_stics","fapar_archimed"]].max().max()*1.05))
        axes[0].set_ylabel("Fraction of incident PAR")
        axes[1].set_ylabel("Daily mean PAR (W/m² of cell)")
        fig.suptitle(f"USM {usm} · STICS {algo}")
        handles=[Line2D([],[],color=colors[s],label=s) for s in case.species.unique()]
        handles += [Line2D([],[],color="black",ls="--",label="STICS interception"),Line2D([],[],color="black",label="Archimed absorption")]
        fig.legend(handles=handles,loc="lower center",ncol=len(handles),frameon=False)
        fig.tight_layout(rect=(0,.07,1,.96));fig.savefig(figures/f"usm_{usm}_{algo}.png",dpi=160);plt.close(fig)
    print(f"Wrote {len(frame)} species-days and {frame.groupby(['usm','algorithm']).ngroups} current case figures to {out}")


if __name__=="__main__":
    main()
