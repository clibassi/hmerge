# dbbench_join_datatable.R -- same-machine data.table reference for the
# db-benchmark join task (duckdblabs/db-benchmark @ 3b074bc, datatable/join-datatable.R).
# Questions and join calls follow the upstream script; tables are read before timing.
# Runs at 2 threads (the core budget of the Stata/MP licence used here) and at all
# threads. Appends rows in the stata-grouplab harness schema.
#
# Usage (repo root): Rscript bench/dbbench/dbbench_join_datatable.R [reps]

suppressMessages(library(data.table))
args <- commandArgs(TRUE)
reps <- if (length(args)) as.integer(args[1]) else 3L
dir  <- "bench/data/dbbench"
out  <- "bench/raw/dbbench_join_datatable.csv"

x      <- fread(file.path(dir, "J1_1e7_NA_0_0.csv"),  showProgress = FALSE, stringsAsFactors = TRUE)
small  <- fread(file.path(dir, "J1_1e7_1e1_0_0.csv"), showProgress = FALSE, stringsAsFactors = TRUE)
medium <- fread(file.path(dir, "J1_1e7_1e4_0_0.csv"), showProgress = FALSE, stringsAsFactors = TRUE)
big    <- fread(file.path(dir, "J1_1e7_1e7_0_0.csv"), showProgress = FALSE, stringsAsFactors = TRUE)

questions <- list(
  q1_small_inner_int   = function() x[small,  on = "id1", nomatch = NULL],
  q2_medium_inner_int  = function() x[medium, on = "id2", nomatch = NULL],
  q3_medium_outer_int  = function() medium[x, on = "id2"],
  q4_medium_inner_fact = function() x[medium, on = "id5", nomatch = NULL],
  q5_big_inner_int     = function() x[big,    on = "id3", nomatch = NULL]
)
J <- c(q1_small_inner_int = 10, q2_medium_inner_int = 1e4, q3_medium_outer_int = 1e4,
       q4_medium_inner_fact = 1e4, q5_big_inner_int = 1e7)

if (!file.exists(out)) {
  cat("bench,case,impl,N,J,keytype,order,rep,seconds,ok,stata_version,host_procs,out_rows\n", file = out)
}
for (threads in c(2L, 0L)) {
  setDTthreads(threads)
  impl <- sprintf("datatable_%sthr", if (threads == 0L) getDTthreads() else threads)
  for (r in seq_len(reps)) {
    for (q in names(questions)) {
      gc()
      t <- system.time(ans <- questions[[q]]())[["elapsed"]]
      cat(sprintf("dbbench,%s,%s,10000000,%d,%s,random,%d,%.4f,1,.,%d,%d\n",
                  q, impl, as.integer(J[[q]]), if (q == "q4_medium_inner_fact") "str" else "int",
                  r, t, getDTthreads(), nrow(ans)), file = out, append = TRUE)
      cat(sprintf("%-22s %-14s rep %d: %.3fs  rows=%d\n", q, impl, r, t, nrow(ans)))
      rm(ans)
    }
  }
}
