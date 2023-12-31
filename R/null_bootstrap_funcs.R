#' Bootstrap null distribution of F statistics for FDR estimation
#'
#' @param df tidy data_frame retrieved after import of a 2D-TPP 
#' dataset, potential filtering and addition of a column "nObs"
#' containing the number of observations per protein
#' @param fcThres numeric value of minimal fold change 
#' (or inverse fold change) a protein has to show to be kept 
#' upon independent filtering
#' @param minObs numeric value of minimal number of observations
#' that should be required per protein
#' @param independentFiltering boolean flag indicating whether
#' independent filtering should be performed based on minimal
#' fold changes per protein profile
#' @param maxit maximal number of iterations the optimization
#' should be given, default is set to 500
#' @param optim_fun_h0 optimization function that should be used
#' for fitting the H0 model
#' @param optim_fun_h1 optimization function that should be used
#' for fitting the H1 model
#' @param optim_fun_h1_2 optional additional optimization function 
#' that will be run with paramters retrieved from optim_fun_h1 and 
#' should be used for fitting the H1 model with the trimmed sum
#' model, default is NULL
#' @param gr_fun_h0 optional gradient function for optim_fun_h0,
#' default is NULL
#' @param gr_fun_h1 optional gradient function for optim_fun_h1,
#' default is NULL
#' @param gr_fun_h1_2 optional gradient function for optim_fun_h1_2,
#' default is NULL
#' @param ncores numeric value of numbers of cores that the function 
#' should use to parallelize
#' @param B numeric value of rounds of bootstrap, default: 20
#' @param byMsExp boolean flag indicating whether resampling of 
#' residuals should be performed separately for data generated by 
#' different MS experiments, default TRUE, recommended 
#' 
#' @return data frame containing F statistics of proteins with 
#' permuted 2D thermal profiles that are informative on the Null
#' distribution of F statistics
#' 
#' @examples
#' data("simulated_cell_extract_df")
#' temp_df <- simulated_cell_extract_df %>% 
#'   filter(clustername %in% paste0("protein", 1:3)) %>% 
#'   group_by(representative) %>% 
#'   mutate(nObs = n()) %>% 
#'   ungroup 
#' boot_df <- bootstrapNull(temp_df, B = 2/10)  
#' 
#' @export
#'
#' @importFrom stats lm
#' @importFrom stats residuals
#' @importFrom stats predict
#' @importFrom foreach foreach
#' @importFrom foreach %dopar%
#' @importFrom doParallel registerDoParallel
#' @importFrom parallel makeCluster
#' @importFrom parallel stopCluster
#' @import dplyr
bootstrapNull <- function(df, maxit = 500,
                          independentFiltering = FALSE,
                          fcThres = 1.5, minObs = 20,
                          optim_fun_h0 = .min_RSS_h0,
                          optim_fun_h1 = .min_RSS_h1_slope_pEC50,
                          optim_fun_h1_2 = NULL,
                          gr_fun_h0 = NULL,
                          gr_fun_h1 = NULL,
                          gr_fun_h1_2 = NULL,
                          ncores = 1,
                          B = 20,
                          byMsExp = TRUE){
  
  clustername <- prot <- log2_value <- experiment <- NULL
  
  .checkDfColumns(df)
  
  if(identical(optim_fun_h1, .min_RSS_h1_slope_pEC50)){
    slopEC50 = TRUE
  }else{
    slopEC50 = FALSE
  }
  
  ec50_limits <- .getEC50Limits(df)
  
  df_fil <- .minObsFilter(df, minObs = minObs)
  
  if(independentFiltering){
    message("Independent Filtering: removing proteins without 
            any values crossing the threshold.")
    df_fil <- .independentFilter(df_fil, fcThres = fcThres) 
  }
  # if(identical(optim_fun_h1, .min_RSS_h1_slope_pEC50_qupm_weight)){
  #     df_fil <- df_fil %>% 
  #         mutate(weight = ifelse(qupm > 1, 1, 0.25)) %>% 
  #         group_by(representative) %>% 
  #         mutate(weight = weight * length(weight)/sum(weight)) %>% 
  #         ungroup
  # }
  cl <- makeCluster(ncores)
  registerDoParallel(cl)
  unique_names <- unique(df_fil$clustername)
  null_list <- foreach(prot = unique_names) %dopar% {
    df_prot <- filter(df_fil, clustername == prot)
    prot_h0 <- lm(log2_value ~ 1 + as.factor(temperature),
                  data = df_prot)
    len_res <- length(residuals(prot_h0))
    
    out_list <- lapply(seq_len(B), function(boot){
      if(!byMsExp){
          df_resample_prot <- df_prot %>%
              mutate(log2_value = log2_value - residuals(prot_h0) +
                         sample(residuals(prot_h0), size = len_res, replace = TRUE))   
      }else{
          exp_res_df <- data.frame(
              experiment = df_prot$experiment,
              res_h0 = residuals(prot_h0),
              pred_h0 = predict(prot_h0)
          )
          df_resample_prot <- bind_rows(
              lapply(unique(df_prot$experiment), function(ms_exp){
                exp_res_tmp = filter(exp_res_df, 
                                     experiment == ms_exp)
                filter(df_prot, experiment == ms_exp) %>% 
                    mutate(log2_value = exp_res_tmp$pred_h0 +
                               sample(exp_res_tmp$res_h0, replace = TRUE))
          }))
          
      }
      
      sum_df <- fitAndEvalDataset(df_resample_prot, 
                                  optim_fun_h0 = optim_fun_h0,
                                  optim_fun_h1 = optim_fun_h1,
                                  optim_fun_h1_2 = optim_fun_h1_2,
                                  gr_fun_h0 = gr_fun_h0,
                                  gr_fun_h1 = gr_fun_h1,
                                  gr_fun_h1_2 = gr_fun_h1_2,
                                  ec50_lower_limit = ec50_limits[1],
                                  ec50_upper_limit = ec50_limits[2],
                                  slopEC50 = slopEC50)
      
      return(sum_df)
    })
  }
  stopCluster(cl)
  null_df <- bind_rows(lapply(null_list, function(x){
    bind_rows(lapply(seq_len(length(x)), function(i){
      x[[i]] %>%
        mutate(dataset = paste("bootstrap", 
                               as.character(i), sep = "_"))
      }))
  }))
  
  return(null_df)
}

#' Bootstrap null distribution of F statistics for FDR estimation
#' based on resampling alternative model residuals
#'
#' @param df tidy data frame retrieved after import of a 2D-TPP 
#' dataset, potential filtering and addition of a column "nObs"
#' containing the number of observations per protein
#' @param params_df data frame listing all null and alternative
#' model parameters as obtained by 'getModelParamsDf'
#' @param fcThres numeric value of minimal fold change 
#' (or inverse fold change) a protein has to show to be kept 
#' upon independent filtering
#' @param minObs numeric value of minimal number of observations
#' that should be required per protein
#' @param independentFiltering boolean flag indicating whether
#' independent filtering should be performed based on minimal
#' fold changes per protein profile
#' @param maxit maximal number of iterations the optimization
#' should be given, default is set to 500
#' @param optim_fun_h0 optimization function that should be used
#' for fitting the H0 model
#' @param optim_fun_h1 optimization function that should be used
#' for fitting the H1 model
#' @param optim_fun_h1_2 optional additional optimization function 
#' that will be run with paramters retrieved from optim_fun_h1 and 
#' should be used for fitting the H1 model with the trimmed sum
#' model, default is NULL
#' @param gr_fun_h0 optional gradient function for optim_fun_h0,
#' default is NULL
#' @param gr_fun_h1 optional gradient function for optim_fun_h1,
#' default is NULL
#' @param gr_fun_h1_2 optional gradient function for optim_fun_h1_2,
#' default is NULL
#' @param BPPARAM BiocParallel parameter for optional parallelization
#' of null distribution generation through bootstrapping, 
#' default: BiocParallel::SerialParam()
#' @param B numeric value of rounds of bootstrap, default: 20
#' @param byMsExp boolean flag indicating whether resampling of 
#' residuals should be performed separately for data generated by 
#' different MS experiments, default TRUE, recommended 
#' @param verbose logical indicating whether to print each 
#' protein while its profile is boostrapped
#' 
#' @return data frame containing F statistics of proteins with 
#' permuted 2D thermal profiles that are informative on the Null
#' distribution of F statistics
#' 
#' @examples
#' data("simulated_cell_extract_df")
#' temp_df <- simulated_cell_extract_df %>% 
#'   filter(clustername %in% paste0("protein", 1:3)) %>% 
#'   group_by(representative) %>% 
#'   mutate(nObs = n()) %>% 
#'   ungroup 
#' temp_params_df <- getModelParamsDf(temp_df)
#' boot_df <- bootstrapNullAlternativeModel(
#'   temp_df, params_df = temp_params_df, B = 2)  
#' 
#' @export
#'
#' @importFrom stats lm
#' @importFrom stats residuals
#' @importFrom stats predict
#' @importFrom utils head
#' @import BiocParallel
#' @import dplyr
bootstrapNullAlternativeModel <- 
    function(df, 
             params_df,
             maxit = 500,
             independentFiltering = FALSE,
             fcThres = 1.5, minObs = 20,
             optim_fun_h0 = TPP2D:::.min_RSS_h0,
             optim_fun_h1 = TPP2D:::.min_RSS_h1_slope_pEC50,
             optim_fun_h1_2 = NULL,
             gr_fun_h0 = NULL,
             gr_fun_h1 = NULL,
             gr_fun_h1_2 = NULL,
             BPPARAM = BiocParallel::SerialParam(progressbar = TRUE),
             B = 20,
             byMsExp = TRUE,
             verbose = FALSE){
      
        clustername <- prot <- log2_value <- experiment <- 
            temperature <- temp_i <- log_conc <- nObs <- NULL 
        
        if(B < 20){
          print(paste("Warning: You have specificed B < 20, it is",
                      "recommended to use at least B = 20 in order", 
                      "to obtain reliable results."))
        }
        
        .checkDfColumns(df)
        
        if(identical(optim_fun_h1, .min_RSS_h1_slope_pEC50)){
            slopEC50 = TRUE
        }else{
            slopEC50 = FALSE
        }
        
        ec50_limits <- .getEC50Limits(df)
        
        df_fil <- .minObsFilter(df, minObs = minObs) %>% 
            mutate(temp_i = dense_rank(temperature)) %>% 
            arrange(clustername, temp_i, log_conc)
        
        if(independentFiltering){
            message("Independent Filtering: removing proteins without 
                    any values crossing the threshold.")
            df_fil <- .independentFilter(df_fil, fcThres = fcThres) 
        }
        unique_names <- unique(df_fil$clustername)
        null_list <- BiocParallel::bplapply(unique_names, BPPARAM = BPPARAM, function(prot){
            if(verbose){
                print(prot)
            }
            df_prot <- filter(df_fil, clustername == prot) 
            params_prot <- head(filter(params_df, clustername == prot) %>% 
                filter(nObs == max(nObs)), 1)
            len_res <- length(params_prot$residualsH0[[1]])
            h0_predicted <- params_prot$estimateH0[[1]]
            unique_temp_prot <- unique(df_prot$temperature)
            len_temp_prot <- length(unique_temp_prot)
            
            out_list <- lapply(seq_len(B), function(boot){
                if(!byMsExp){
                    df_resample_prot <- df_prot %>%
                        mutate(log2_value = h0_predicted +
                                   sample(params_prot$residualsH1[[1]], 
                                          size = len_res, replace = TRUE))   
                }else{
                    exp_res_df <- data.frame(
                        experiment = df_prot$experiment,
                        res_h1 = params_prot$residualsH1[[1]],
                        pred_h0 = h0_predicted
                    )
                    df_resample_prot <- bind_rows(
                        lapply(unique(df_prot$experiment), function(ms_exp){
                            exp_res_tmp = filter(exp_res_df, 
                                                 experiment == ms_exp)
                            filter(df_prot, experiment == ms_exp) %>% 
                                mutate(log2_value = exp_res_tmp$pred_h0 +
                                           sample(exp_res_tmp$res_h1, replace = TRUE))
                        }))
                    
                }
                
                sum_df <- fitAndEvalDataset(df_resample_prot, 
                                            optim_fun_h0 = optim_fun_h0,
                                            optim_fun_h1 = optim_fun_h1,
                                            optim_fun_h1_2 = optim_fun_h1_2,
                                            gr_fun_h0 = gr_fun_h0,
                                            gr_fun_h1 = gr_fun_h1,
                                            gr_fun_h1_2 = gr_fun_h1_2,
                                            ec50_lower_limit = ec50_limits[1],
                                            ec50_upper_limit = ec50_limits[2],
                                            slopEC50 = slopEC50)
                
                return(sum_df)
            })
        })
        null_df <- bind_rows(lapply(null_list, function(x){
            bind_rows(lapply(seq_len(length(x)), function(i){
                if("data.frame" %in% class(x[[i]])){
                    x[[i]] %>%
                        mutate(dataset = paste("bootstrap", 
                                               as.character(i), sep = "_"))
                }else{
                    tibble()
                }
            }))
        }))
        
        return(null_df)
    }

#' Bootstrap null distribution of F statistics for FDR estimation
#' based on resampling alternative model residuals with only
#' one round of model fitting on resampled data and subsequent
#' resampling of thereby obtained residuals
#'
#' @param df tidy data frame retrieved after import of a 2D-TPP 
#' dataset, potential filtering and addition of a column "nObs"
#' containing the number of observations per protein
#' @param params_df data frame listing all null and alternative
#' model parameters as obtained by 'getModelParamsDf'
#' @param fcThres numeric value of minimal fold change 
#' (or inverse fold change) a protein has to show to be kept 
#' upon independent filtering
#' @param minObs numeric value of minimal number of observations
#' that should be required per protein
#' @param independentFiltering boolean flag indicating whether
#' independent filtering should be performed based on minimal
#' fold changes per protein profile
#' @param maxit maximal number of iterations the optimization
#' should be given, default is set to 500
#' @param optim_fun_h0 optimization function that should be used
#' for fitting the H0 model
#' @param optim_fun_h1 optimization function that should be used
#' for fitting the H1 model
#' @param optim_fun_h1_2 optional additional optimization function 
#' that will be run with paramters retrieved from optim_fun_h1 and 
#' should be used for fitting the H1 model with the trimmed sum
#' model, default is NULL
#' @param gr_fun_h0 optional gradient function for optim_fun_h0,
#' default is NULL
#' @param gr_fun_h1 optional gradient function for optim_fun_h1,
#' default is NULL
#' @param gr_fun_h1_2 optional gradient function for optim_fun_h1_2,
#' default is NULL
#' @param BPPARAM BiocParallel parameter for optional parallelization
#' of null distribution generation through bootstrapping, 
#' default: BiocParallel::SerialParam()
#' @param B numeric value of rounds of bootstrap, default: 20
#' @param byMsExp boolean flag indicating whether resampling of 
#' residuals should be performed separately for data generated by 
#' different MS experiments, default TRUE, recommended 
#' @param verbose logical indicating whether to print each 
#' protein while its profile is boostrapped
#' 
#' @return data frame containing F statistics of proteins with 
#' permuted 2D thermal profiles that are informative on the Null
#' distribution of F statistics
#' 
#' @examples
#' data("simulated_cell_extract_df")
#' temp_df <- simulated_cell_extract_df %>% 
#'   filter(clustername %in% paste0("protein", 1:3)) %>% 
#'   group_by(representative) %>% 
#'   mutate(nObs = n()) %>% 
#'   ungroup 
#' temp_params_df <- getModelParamsDf(temp_df)
#' boot_df <- bootstrapNullAlternativeModelFast(
#'   temp_df, params_df = temp_params_df, B = 20)  
#' 
#' @export
#'
#' @importFrom stats lm
#' @importFrom stats residuals
#' @importFrom stats predict
#' @importFrom utils head
#' @import BiocParallel
#' @import dplyr
bootstrapNullAlternativeModelFast <- 
  function(df, 
           params_df,
           maxit = 500,
           independentFiltering = FALSE,
           fcThres = 1.5, minObs = 20,
           optim_fun_h0 = TPP2D:::.min_RSS_h0,
           optim_fun_h1 = TPP2D:::.min_RSS_h1_slope_pEC50,
           optim_fun_h1_2 = NULL,
           gr_fun_h0 = NULL,
           gr_fun_h1 = NULL,
           gr_fun_h1_2 = NULL,
           BPPARAM = BiocParallel::SerialParam(progressbar = TRUE),
           B = 20,
           byMsExp = TRUE,
           verbose = FALSE){
    
    clustername <- prot <- log2_value <- experiment <- 
      temperature <- temp_i <- log_conc <- nObs <- NULL 
    
    if(B < 20){
      print(paste("Warning: You have specificed B < 20, it is",
                  "recommended to use at least B = 20 in order", 
                  "to obtain reliable results."))
    }
    
    .checkDfColumns(df)
    
    if(identical(optim_fun_h1, .min_RSS_h1_slope_pEC50)){
      slopEC50 = TRUE
    }else{
      slopEC50 = FALSE
    }
    
    ec50_limits <- .getEC50Limits(df)
    
    df_fil <- .minObsFilter(df, minObs = minObs) %>% 
      mutate(temp_i = dense_rank(temperature)) %>% 
      arrange(clustername, temp_i, log_conc)
    
    if(independentFiltering){
      message("Independent Filtering: removing proteins without 
                    any values crossing the threshold.")
      df_fil <- .independentFilter(df_fil, fcThres = fcThres) 
    }
    unique_names <- unique(df_fil$clustername)
    null_list <- BiocParallel::bplapply(unique_names, BPPARAM = BPPARAM, function(prot){
      if(verbose){
        print(prot)
      }
      df_prot <- filter(df_fil, clustername == prot) 
      params_prot <- head(filter(params_df, clustername == prot) %>% 
                            filter(nObs == max(nObs)), 1)
      len_res <- length(params_prot$residualsH0[[1]])
      h0_predicted <- params_prot$estimateH0[[1]]
      unique_temp_prot <- unique(df_prot$temperature)
      len_temp_prot <- length(unique_temp_prot)
      
      if(!byMsExp){
        df_resample_prot <- df_prot %>%
          mutate(log2_value = h0_predicted +
                   sample(params_prot$residualsH1[[1]], 
                          size = len_res, replace = TRUE))   
      }else{
        exp_res_df <- data.frame(
          experiment = df_prot$experiment,
          res_h1 = params_prot$residualsH1[[1]],
          pred_h0 = h0_predicted
        )
        df_resample_prot <- bind_rows(
          lapply(unique(df_prot$experiment), function(ms_exp){
            exp_res_tmp = filter(exp_res_df, 
                                 experiment == ms_exp)
            filter(df_prot, experiment == ms_exp) %>% 
              mutate(log2_value = exp_res_tmp$pred_h0 +
                       sample(exp_res_tmp$res_h1, replace = TRUE))
          }))
        
      }
      
      params_df <- getModelParamsDf(df_resample_prot, 
                                    minObs = minObs,
                                    optim_fun_h0 = optim_fun_h0,
                                    optim_fun_h1 = optim_fun_h1,
                                    optim_fun_h1_2 = optim_fun_h1_2,
                                    gr_fun_h0 = gr_fun_h0,
                                    gr_fun_h1 = gr_fun_h1,
                                    gr_fun_h1_2 = gr_fun_h1_2,
                                    slopEC50 = slopEC50)
      
      out_list <- lapply(seq_len(B), function(boot){
        b_nobs <- params_df$nObs
        ids_resampled <- sample(seq(b_nobs), replace = TRUE)
        params_df$residualsH0[[1]] <-  params_df$residualsH0[[1]][ids_resampled]
        params_df$residualsH1[[1]] <-  params_df$residualsH1[[1]][ids_resampled]
        params_df$rssH0 <- sum(params_df$residualsH0[[1]]^2)
        params_df$rssH1 <- sum(params_df$residualsH1[[1]]^2)
        fstat_df <- computeFStatFromParams(params_df)
        return(fstat_df)
      })
    })
    null_df <- bind_rows(lapply(null_list, function(x){
      bind_rows(lapply(seq_len(length(x)), function(i){
        if("data.frame" %in% class(x[[i]])){
          x[[i]] %>%
            mutate(dataset = paste("bootstrap", 
                                   as.character(i), sep = "_"))
        }else{
          tibble()
        }
      }))
    }))
    
    return(null_df)
  }
