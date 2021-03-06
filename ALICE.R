library(data.table)
library(igraph)
library(stringdist)
ALICE_lib <- file.path('~/libs', 'ALICE')
load(file.path(ALICE_lib, 'VDJT.rda'))
source(file.path(ALICE_lib, 'generation.R'))


#' Add space occupied by sequence neighbours. hugedf contains information of
#' CDR3aa sequence and its generative probability.
#'
add_space <- function(df, hugedf, volume = 66e6) {
  huge <- hugedf$sim_num
  names(huge) <- hugedf$CDR3.amino.acid.sequence
  if (nrow(df)==0) return(0)
  else {
    space <- numeric(nrow(df))
    tstl <- lapply(df$CDR3.amino.acid.sequence, all_other_variants_one_mismatch)
    for (i in 1:nrow(df)) {
      space[i] <- sum(huge[tstl[[i]]])
    }
    space_n <- space / volume
    df$space <- space
    df$space_n <- space_n
    return(df)
  }
}


#' Adds column with p_value
#'
#'
add_p_val<-function(df, total, correct = 9.41) {
  if (!is.null(nrow(df))) {
    if (correct == "auto") {
      tmp <- df$space_n * total
      correct <- coef(lm(df$D ~ tmp + 0))[1]
    }
    df$p_val <- pbinom(q=df$D, size = total,
                       prob = correct*df$space_n, lower.tail = F)
    return(df)
  } else {
    return(df)
  }
}


igraph_from_seqs <- function(seqs, max_errs = 1) {
  graph <- igraph::graph.empty(n = length(seqs), directed = F)
  tmp <- stringdist::stringdistmatrix(seqs, seqs, method = "hamming")
  graph <- igraph::add.edges(graph, t(which(tmp <= max_errs, arr.ind = T)))
  graph <- igraph::simplify(graph)
  graph <- igraph::set.vertex.attribute(graph, 'label', V(graph), seqs)
  return(graph)
}


filter_data <- function(df) {
  gr <- igraph_from_seqs(df$CDR3.amino.acid.sequence)
  df$D <- degree(gr)
  df$cl <- clusters(gr)$membership
  df[df$D>0,]
}


#' Performs multiple testing correction and returns list of significant results.
#'
#'
select_sign <- function(sign_list, D_thres = 2, P_thres = 0.001,
                        cor_method = "BH") {
  lapply(sign_list, function(x)
    x[D>D_thres&space!=0][p.adjust(p_val, method = cor_method) < P_thres])
}


all_other_letters <- function(str, ind = 8) {
  aa <- c("A", "C", "D", "E", "F", "G", "H", "I", "K", "L", "M", "N",
          "P", "Q", "R", "S", "T", "V", "W", "Y")
  paste0(substr(str, 1, ind - 1), aa, substr(str, ind + 1, nchar(str)))
}


all_other_variants_one_mismatch <- function(str) {
  unique(as.vector(sapply(2:(nchar(str) - 1), all_other_letters, str = str)))
}


convert_comblist_to_df <- function(comblist) {
  newl <- list()
  for (i in 1:length(comblist[[1]])){
    newl[[i]] <- lapply(comblist, "[[" , i)
    names(newl)[i] <- names(comblist[[1]])[i]
    newl[[i]] <- do.call(rbind, newl[[i]][sapply(newl[[i]],is.list)])
  }
  return(newl)
}


#' Pipeline functions
#'
#'
make_rda_folder <- function(DTlist, folder = "", prefix = "",
                            Read_thres = 0, VJDT = VDJT, overwrite = F) {
  dir.create(folder, showWarnings = FALSE, recursive = T)
  VJDT <- as.data.table(VJDT)
  VJDT[, bestVGene := V]
  VJDT[, bestJGene := J]

  for (i in 1:nrow(VJDT)) {
    fname <- file.path(folder, 
                       paste0(prefix, VJDT[i,as.character(bestVGene)],
                              "_", VJDT[i, as.character(bestJGene)], ".rda"))
    if (file.exists(fname) && !overwrite) next

    all_short_i <- lapply(DTlist, function(x)
      x[bestVGene == VJDT$bestVGene[i] & bestJGene == VJDT$bestJGene[i] &
        Read.count > Read_thres])
    all_short_int <- lapply(all_short_i, filter_data)
    all_short_int2 <- lapply(all_short_int, function(x) x[D>2,])
    hugel <- unlist(lapply(unique(unlist(lapply(all_short_int2,
              function(x) { if(nrow(x)>0) x[,CDR3.amino.acid.sequence] }))),
              all_other_variants_one_mismatch))
    shrep <- data.frame(CDR3.amino.acid.sequence = unique(hugel))
    if (nrow(shrep) != 0) {
      save(shrep, file = fname)
    }
  }
  if (length(list.files(folder)) == 0) {
    warning(sprintf('No files were created in %s', folder))
  }
}

compute_pgen_rda_folder<-function(folder, prefix = "", iter = 50, cores = 8, 
                                  nrec = 5e5, silent = T, overwrite = F) {
  fnames <- list.files(folder, full.names = T)
  if (length(fnames) == 0) {
    warning(sprintf('No files in %s', folder))
    return(NULL)
  }
  fnames_s <- list.files(folder, full.names = F)
  fnames <- grep(pattern = "res_", fnames, invert = T, value = T)
  fnames_s <- grep(pattern = "res_",fnames_s, invert = T, value = T)
  fnames_s <- gsub(".rda", "", fnames_s)
  fnames_s <- gsub(prefix, "", fnames_s)
  VJlist <- do.call(rbind,strsplit(fnames_s, "_"))

  for (i in 1:nrow(VJlist)) {
    #test if present
    if (VJlist[i,1] %in% segments$TRBV$V.alleles &&
        VJlist[i,2] %in% segments$TRBJ$J.alleles) {
      o_fn <- file.path(folder, 
                        paste0("res_", prefix, fnames_s[i], ".rda"))
      if (file.exists(o_fn) && !overwrite) next
      if (!silent) print(fnames_s[i])
      if (!silent) print(format(Sys.time(), "%a %b %d %X %Y"))

      load(fnames[i])
      res <- data.frame()
      if (nrow(shrep) != 0) {
        res <- estimate_pgen_aa(data = shrep,iter = iter, cores = cores, 
                                nrec = nrec, V = VJlist[i,1], J = VJlist[i,2])
      }
      if (!silent) print("all iterations done")
      save(res, file = o_fn)
      if (!silent) print(format(Sys.time(), "%a %b %d %X %Y"))
      if (!silent) print("result saved")
      rm(res)
    }
  }
  # return amount of files (i.e. unique V-J combinations for which clusters are
  # found) are generated
  return(length(list.files(folder, pattern = "res_.*.rda")))
}


#' Gets folder, returns space and space_n, and add significant also.
#'
#'
parse_rda_folder<-function(DTlist, folder, prefix = "", Q = 9.41,
                           volume = 66e6, Read_thres = 1, silent = T) {
  fnames <- list.files(folder, pattern = "res_", full.names = T)
  fnames_s <- list.files(folder, pattern = "res_", full.names = F)
  fnames_s <- gsub("res_", "", fnames_s)
  fnames_s <- gsub(".rda", "", fnames_s)
  fnames_s <- gsub(prefix, "", fnames_s)
  VJlist <- do.call(rbind, strsplit(fnames_s, "_"))
  resl <- list()
  for (i in 1:nrow(VJlist)) {
    if (!silent) print(i)
    all_short_i <- lapply(DTlist, function(x)
                          x[bestVGene == VJlist[i,1] & 
                            bestJGene == VJlist[i,2] & 
                            Read.count > Read_thres])
    all_short_int <- lapply(all_short_i, filter_data)
    all_short_int2 <- lapply(all_short_int, function(x) x[D>2,])
    load(fnames[i])
    all_short_int2_space <- lapply(all_short_int2, add_space, hugedf = res, 
                                   volume = volume)
    for (j in 1:length(all_short_int2_space)) {
      all_short_int2_space[[j]] <-
        add_p_val(all_short_int2_space[[j]],
                  total = nrow(all_short_i[[j]][Read.count > Read_thres]),
                  correct = Q)
    }
    resl[[i]] <- all_short_int2_space
  }
  names(resl) <- fnames_s
  return(resl)
}


#' Run pipeline function.
#'
#'
ALICE_pipeline <- function(DTlist, folder = "", cores = 8, iter = 50, 
                           nrec = 5e5, P_thres = 0.001, Read_thres = 1, 
                           cor_method = "BH") {
  # generate .rda files for CDR3aa gen prob estimation for each VJ
  make_rda_folder(DTlist, folder, Read_thres = Read_thres)
  # estimate CDR3aa gen prob for each sequence and save to separate res_ files
  # return the amount of files generated
  file_no <- 
    compute_pgen_rda_folder(folder, cores = cores, nrec = nrec, iter = iter)
  if (is.null(file_no) || file_no == 0) {
    warning(sprintf('No clusters found in %s', folder))
    return(NULL)
  }
  # parse res_ files
  results <- parse_rda_folder(DTlist, folder, volume = cores * iter * nrec / 3,
                              Read_thres = Read_thres)
  # convert to single dataset from VJ-combs
  results <- convert_comblist_to_df(results)
  # filter for significant results
  select_sign(results[!sapply(results,is.null)], P_thres = P_thres,
              cor_method = cor_method)
}
