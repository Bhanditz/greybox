#' Combine regressions based on point information criteria
#'
#' Function combines parameters of linear regressions of the first variable
#' on all the other provided data using pAIC weights
#'
#' The algorithm uses alm() to fit different models and then combines the models
#' based on the selected point IC. This is a dynamic counterpart of
#' \link[greybox]{lmCombine} function.
#'
#' @template AICRef
#' @template author
#' @template keywords
#'
#' @param data Data frame containing dependent variable in the first column and
#' the others in the rest.
#' @param ic Information criterion to use.
#' @param bruteForce If \code{TRUE}, then all the possible models are generated
#' and combined. Otherwise the best model is found and then models around that
#' one are produced and then combined.
#' @param silent If \code{FALSE}, then nothing is silent, everything is printed
#' out. \code{TRUE} means that nothing is produced.
#' @param distribution Distribution to pass to \code{alm()}.
#' @param parallel If \code{TRUE}, then the model fitting is done in parallel.
#' WARNING! Packages \code{foreach} and either \code{doMC} (Linux and Mac only)
#' or \code{doParallel} are needed in order to run the function in parallel.
#' @param ... Other parameters passed to \code{alm()}.
#'
#' @return Function returns \code{model} - the final model of the class
#' "greyboxD", which includes time varying parameters and dynamic importance
#' of each variable. The list of variables:
#' \itemize{
#' \item coefficients - mean (over time) parameters of the model,
#' \item se - mean standard errors of the parameters of the model,
#' \item fitted.values - the fitted values,
#' \item residuals - residual of the model,
#' \item distribution - distribution used in the estimation,
#' \item logLik - mean (over time) log-likelihood of the model,
#' \item IC - dynamic values of the information criterion (pIC),
#' \item df.residual - mean number of degrees of freedom of the residuals of
#' the model,
#' \item df - mean number of degrees of freedom of the model,
#' \item importance - dynamic importance of the parameters,
#' \item call - call used in the function,
#' \item rank - rank of the combined model,
#' \item data - the data used in the model,
#' \item mu - the location value of the distribution,
#' \item scale - the scale parameter if alm() was used,
#' \item coefficientsDynamic - table with parameters of the model, varying over
#' the time,
#' \item df.residualDynamic - dynamic df.residual,
#' \item dfDynamic - dynamic df.
#' }
#'
#' @seealso \code{\link[greybox]{stepwise}, \link[greybox]{lmCombine}}
#'
#' @examples
#'
#' ### Simple example
#' xreg <- cbind(rnorm(100,10,3),rnorm(100,50,5))
#' xreg <- cbind(100+0.5*xreg[,1]-0.75*xreg[,2]+rnorm(100,0,3),xreg,rnorm(100,300,10))
#' colnames(xreg) <- c("y","x1","x2","Noise")
#' inSample <- xreg[1:80,]
#' outSample <- xreg[-c(1:80),]
#' # Combine all the possible models
#' ourModel <- lmDynamic(inSample,bruteForce=TRUE)
#' predict(ourModel,outSample)
#' plot(predict(ourModel,outSample))
#'
#' @export lmDynamic
lmDynamic <- function(data, ic=c("AICc","AIC","BIC","BICc"), bruteForce=FALSE, silent=TRUE,
                      distribution=c("dnorm","dfnorm","dlnorm","dlaplace","ds","dchisq","dlogis",
                                    "plogis","pnorm"),
                      parallel=FALSE, ...){
    # Function combines linear regression models and produces the combined lm object.
    cl <- match.call();
    cl$formula <- as.formula(paste0(colnames(data)[1]," ~ ."));

    ellipsis <- list(...);

    # If they asked for parallel, make checks and try to do that
    if(parallel){
        if(!requireNamespace("foreach", quietly = TRUE)){
            stop("In order to run the function in parallel, 'foreach' package must be installed.", call. = FALSE);
        }
        if(!requireNamespace("parallel", quietly = TRUE)){
            stop("In order to run the function in parallel, 'parallel' package must be installed.", call. = FALSE);
        }
        # Detect number of cores for parallel calculations
        nCores <- parallel::detectCores();

        # Check the system and choose the package to use
        if(Sys.info()['sysname']=="Windows"){
            if(requireNamespace("doParallel", quietly = TRUE)){
                cat(paste0("Setting up ", nCores, " clusters using 'doParallel'..."));
                cat("\n");
                cluster <- parallel::makeCluster(nCores);
                doParallel::registerDoParallel(cluster);
            }
            else{
                stop("Sorry, but in order to run the function in parallel, you need 'doParallel' package.",
                     call. = FALSE);
            }
        }
        else{
            if(requireNamespace("doMC", quietly = TRUE)){
                doMC::registerDoMC(nCores);
                cluster <- NULL;
            }
            else if(requireNamespace("doParallel", quietly = TRUE)){
                cat(paste0("Setting up ", nCores, " clusters using 'doParallel'..."));
                cat("\n");
                cluster <- parallel::makeCluster(nCores);
                doParallel::registerDoParallel(cluster);
            }
            else{
                stop("Sorry, but in order to run the function in parallel, you need either 'doMC' (prefered) or 'doParallel' packages.",
                     call. = FALSE);
            }
        }
    }

    # Define cases, when to use ALM
    distribution <- distribution[1];
    if(distribution=="dnorm"){
        useALM <- FALSE;
    }
    else{
        useALM <- TRUE;
        if(any(distribution==c("plogis","pnorm"))){
            data[,1] <- (data[,1]!=0)*1;
            ot <- (data[,1]!=0)*1;
        }
    }

    # If the data is a vector, make it a matrix
    if(is.null(dim(data))){
        data <- as.matrix(data);
        colnames(data) <- as.character(cl$formula[[2]]);
    }

    # Check the data for NAs
    if(any(is.na(data))){
        rowsSelected <- apply(!is.na(data),1,all);
    }
    else{
        rowsSelected <- rep(TRUE,nrow(data));
    }

    # Check occurrence. If it is not "none" then use alm().
    # if(is.alm(occurrence)){
    #     useALM <- TRUE;
    #     rowsSelected <- rowsSelected & (data[,1]!=0);
    # }
    # else{
    #     occurrence <- occurrence[1];
    #     if(all(occurrence!=c("none","plogis","pnorm"))){
    #         warning(paste0("Sorry, but we don't know what to do with the occurrence '",occurrence,
    #                     "'. Switching to 'none'."), call.=FALSE);
    #         occurrence <- "none";
    #     }
    #
    #     if(any(occurrence==c("plogis","pnorm"))){
    #         useALM <- TRUE;
    #         rowsSelected <- rowsSelected | (data[,1]!=0);
    #
    #         occurrenceModel <- lmCombine(data, ic=ic, bruteForce=bruteForce, silent=silent,
    #                                      distribution=occurrence, parallel=parallel, ...);
    #         occurrenceModel$call <- cl;
    #     }
    # }

    ic <- ic[1];
    if(ic=="AIC"){
        IC <- pAIC;
    }
    else if(ic=="AICc"){
        IC <- pAICc;
    }
    else if(ic=="BIC"){
        IC <- pBIC;
    }
    else if(ic=="BICc"){
        IC <- pBICc;
    }

    # Define what function to use in the estimation
    if(useALM){
        lmCall <- alm;
        listToCall <- list(distribution=distribution, checks=FALSE);
        listToCall <- c(listToCall,ellipsis);
    }
    else{
        lmCall <- function(formula, data){
            model <- list(xreg=as.matrix(cbind(1,data[,all.vars(formula)[-1]])));
            model <- c(model,.lm.fit(model$xreg, y));
            colnames(model$qr) <- c("(Intercept)",all.vars(formula)[-1]);
            return(structure(model,class=c("lmGreybox","lm")));
        }
        listToCall <- vector("list");
    }

    # Name of the response
    responseName <- as.character(cl$formula[[2]]);
    y <- as.matrix(data[,responseName]);
    colnames(y) <- responseName;

    # Check whether it is possible to do bruteForce
    if((ncol(data)>nrow(data)) & bruteForce){
        warning("You have more variables than observations. We have to be smart here. Switching to 'bruteForce=FALSE'.");
        bruteForce <- FALSE;
    }

    # Warning if we have a lot of models
    if((ncol(data)>14) & bruteForce){
        warning("You have more than 14 variables. The computation might take a lot of time.");
    }

    # If this is not bruteForce, then do stepwise first
    if(!bruteForce){
        if(!silent){
            cat("Selecting the best model...\n");
        }
        bestModel <- stepwise(data, ic=ic, distribution=distribution, silent=silent);
    }

    # Modify the data and move to the list
    if(is.data.frame(data)){
        listToCall$data <- cbind(y,model.matrix(cl$formula, data=data[rowsSelected,])[,-1]);
    }
    else{
        listToCall$data <- cbind(y,as.data.frame(data[rowsSelected,-1]));
    }
    rm(data);

    # Set alpha for the dalaplace
    if(distribution=="dalaplace"){
        listToCall$alpha <- ellipsis$alpha;
        if(is.null(ellipsis$alpha)){
            alpha <- 0.5;
        }
        else{
            alpha <- ellipsis$alpha;
        }
    }

    # Observations in sample, assuming that the missing values are for the holdout
    obsInsample <- sum(!is.na(listToCall$data[,1]));
    # Names of the exogenous variables (without the intercept)
    exoNames <- colnames(listToCall$data)[-1];
    # Names of all the variables
    variablesNames <- c("(Intercept)",exoNames);
    # Number of variables
    nVariables <- length(exoNames);

    # If nVariables is zero, return a simple model. This might be due to the stepwise returning intercept.
    if(nVariables==0){
        warning("No explanatory variables are selected / provided. Fitting the model with intercept only.", call.=FALSE);
        if(bruteForce){
            return(alm(as.formula(paste0(responseName,"~1")),listToCall$data,distribution=distribution,...));
        }
        else{
            return(bestModel);
        }
    }

    # If this is a simple one, go through all the models
    if(bruteForce){
        # Number of combinations in the loop
        nCombinations <- 2^nVariables;
        # Matrix of all the combinations
        variablesBinary <- rep(1,nVariables);
        variablesCombinations <- matrix(NA,nCombinations,nVariables);
        colnames(variablesCombinations) <- exoNames;

        #Produce matrix with binaries for inclusion of variables in the loop
        variablesCombinations[,1] <- rep(c(0:1),times=prod(variablesBinary[-1]+1));
        for(i in 2:nVariables){
            variablesCombinations[,i] <- rep(c(0:variablesBinary[i]),each=prod(variablesBinary[1:(i-1)]+1));
        }

        # Vector of ICs
        pICs <- matrix(NA,obsInsample,nCombinations);
        # Matrix of parameters
        parameters <- matrix(0,nCombinations,nVariables+1);
        # Matrix of s.e. of parameters
        parametersSE <- matrix(0,nCombinations,nVariables+1);
        # Matrix of point likelihoods
        pointLiks <- matrix(NA,obsInsample,nCombinations);

        # Starting estimating the models with just a constant
        listToCall$formula <- as.formula(paste0(responseName,"~1"));
        ourModel <- do.call(lmCall,listToCall);
        pICs[,1] <- IC(ourModel);
        parameters[1,1] <- coef(ourModel)[1];
        parametersSE[1,1] <- diag(vcov(ourModel));
        pointLiks[,1] <- pointLik(ourModel);
    }
    else{
        # Extract names of the used variables
        bestExoNames <- names(coef(bestModel))[-1];
        # If the number of variables is small, do bruteForce
        if(nParam(bestModel)<16){
            bestModel <- lmDynamic(listToCall$data[,c(responseName,bestExoNames)], ic=ic,
                                   bruteForce=TRUE, silent=silent, distribution=distribution, parallel=parallel, ...);
            bestModel$call <- cl;
            return(bestModel);
        }
        # If we have too many variables, use "stress" analysis
        else{
            nVariablesInModel <- length(bestExoNames);
            # Define number of combinations:
            # 1. Best model
            nCombinations <- 1;
            # 2. BM + {each variable not included};
            nCombinations <- nCombinations + nVariables - nVariablesInModel;
            # 3. BM - {each variable included};
            nCombinations <- nCombinations + nVariablesInModel;

            ## 4. BM + {each pair of variables not included};
            ## 5. BM - {each pair of variables included}.

            # Form combinations of variables
            variablesCombinations <- matrix(NA,nCombinations,nVariables);
            colnames(variablesCombinations) <- exoNames;
            # Fill in the first row with the variables from the best model
            for(j in 1:nVariables){
                variablesCombinations[,j] <- any(colnames(variablesCombinations)[j]==bestExoNames)*1;
            }

            # Fill in the first part with sequential inclusion
            for(i in 1:(nVariables - nVariablesInModel)){
                variablesCombinations[i+1,which(variablesCombinations[i+1,]==0)[i]] <- 1;
            }

            # Fill in the second part with sequential exclusion
            for(i in 1:nVariablesInModel){
                index <- i+(nVariables-nVariablesInModel)+1;
                variablesCombinations[index,which(variablesCombinations[index,]==1)[i]] <- 0;
            }

            # Vector of ICs
            pICs <- matrix(NA,obsInsample,nCombinations);
            # Matrix of parameters
            parameters <- matrix(0,nCombinations,nVariables+1);
            # Matrix of s.e. of parameters
            parametersSE <- matrix(0,nCombinations,nVariables+1);
            # Matrix of point likelihoods
            pointLiks <- matrix(NA,obsInsample,nCombinations);

            # Starting estimating the models with writing down the best one
            pICs[,1] <- IC(bestModel);
            bufferCoef <- coef(bestModel)[variablesNames];
            parameters[1,c(1,variablesCombinations[1,])==1] <- bufferCoef[!is.na(bufferCoef)];
            bufferCoef <- diag(vcov(bestModel))[variablesNames];
            parametersSE[1,c(1,variablesCombinations[1,])==1] <- bufferCoef[!is.na(bufferCoef)];
            pointLiks[,1] <- pointLik(bestModel);
        }
    }

    if(any(distribution==c("dchisq","dnbinom","dalaplace"))){
        otherParameters <- rep(NA, nCombinations);
        otherParameters[1] <- bestModel$other[[1]];
    }

    # Go for the loop of lm models
    if(parallel){
        if(!silent){
            cat("Estimation progress: ...");
        }
        forLoopReturns <- foreach::`%dopar%`(foreach::foreach(i=2:nCombinations),{
            listToCall$formula <- as.formula(paste0(responseName,"~",paste0(exoNames[variablesCombinations[i,]==1],collapse="+")));
            ourModel <- do.call(lmCall,listToCall);

            ICs <- IC(ourModel);
            parameters <- coef(ourModel);
            parametersSE <- diag(vcov(ourModel));
            pointLiks <- pointLik(ourModel);

            if(any(distribution==c("dchisq","dnbinom","dalaplace"))){
                otherParameters <- ourModel$other[[1]];
            }
            else{
                otherParameters <- NULL;
            }
            return(list(ICs=ICs,parameters=parameters,parametersSE=parametersSE,
                        pointLiks=pointLiks,otherParameters=otherParameters));
        });

        for(i in 2:nCombinations){
            pICs[,i] <- forLoopReturns[[i-1]]$ICs;
            parameters[i,c(1,variablesCombinations[i,])==1] <- forLoopReturns[[i-1]]$parameters;
            parametersSE[i,c(1,variablesCombinations[i,])==1] <- forLoopReturns[[i-1]]$parametersSE;
            pointLiks[,i] <- forLoopReturns[[i-1]]$pointLiks;

            if(any(distribution==c("dchisq","dnbinom","dalaplace"))){
                otherParameters[i] <- forLoopReturns[[i-1]]$otherParameters;
            }
        }

        if(!is.null(cluster)){
            parallel::stopCluster(cluster);
        }
    }
    else{
        if(!silent){
            cat(paste0("Estimation progress: ", round(1/nCombinations,2)*100,"%"));
        }
        for(i in 2:nCombinations){
            if(!silent){
                cat(paste0(rep("\b",nchar(round((i-1)/nCombinations,2)*100)+1),collapse=""));
                cat(paste0(round(i/nCombinations,2)*100,"%"));
            }
            listToCall$formula <- as.formula(paste0(responseName,"~",paste0(exoNames[variablesCombinations[i,]==1],collapse="+")));
            ourModel <- do.call(lmCall,listToCall);

            pICs[,i] <- IC(ourModel);
            parameters[i,c(1,variablesCombinations[i,])==1] <- coef(ourModel);
            parametersSE[i,c(1,variablesCombinations[i,])==1] <- diag(vcov(ourModel));
            pointLiks[,i] <- pointLik(ourModel);

            if(any(distribution==c("dchisq","dnbinom","dalaplace"))){
                otherParameters[i] <- ourModel$other[[1]];
            }
        }
    }

    # Calculate IC weights
    pICWeights <- pICs - apply(pICs,1,min);
    pICWeights <- exp(-0.5*pICWeights) / apply(exp(-0.5*pICWeights),1,sum)
    pICWeightsMean <- apply(pICWeights,2,mean);

    # Calculate weighted parameters
    parametersWeighted <- pICWeights %*% parameters;
    colnames(parametersWeighted) <- variablesNames;

    parametersMean <- colMeans(parametersWeighted);
    names(parametersMean) <- variablesNames;

    # From the matrix of exogenous variables without the response variable
    ourDataExo <- cbind(1,listToCall$data[,-1]);
    colnames(ourDataExo) <- variablesNames;

    # Calculate the mean based on the mean values of parameters
    mu <- switch(distribution,
                 "dpois" = exp(as.matrix(ourDataExo) %*% parametersMean),
                 "dchisq" = (as.matrix(ourDataExo) %*% parametersMean)^2,
                 "dnbinom" = exp(as.matrix(ourDataExo) %*% parametersMean),
                 "dnorm" =,
                 "dfnorm" =,
                 "dlnorm" =,
                 "dlaplace" =,
                 "dalaplace" =,
                 "dlogis" =,
                 "dt" =,
                 "ds" =,
                 "pnorm" =,
                 "plogis" = as.matrix(ourDataExo) %*% parametersMean
    );

    scale <- switch(distribution,
                    "dnorm" =,
                    "dfnorm" = sqrt(mean((y-mu)^2)),
                    "dlnorm" = sqrt(mean((log(y)-mu)^2)),
                    "dlaplace" = mean(abs(y-mu)),
                    "dalaplace" = mean((y-mu) * (alpha - (y<=mu)*1)),
                    "dlogis" = sqrt(mean((y-mu)^2) * 3 / pi^2),
                    "ds" = mean(sqrt(abs(y-mu))) / 2,
                    "dt" = max(2,2/(1-(mean((y-mu)^2))^{-1})),
                    "dchisq" = pICWeightsMean %*% otherParameters,
                    "dnbinom" = pICWeightsMean %*% otherParameters,
                    "dpois" = mu,
                    "pnorm" = sqrt(mean(qnorm((y - pnorm(mu, 0, 1) + 1) / 2, 0, 1)^2)),
                    "plogis" = sqrt(mean(log((1 + y * (1 + exp(mu))) / (1 + exp(mu) * (2 - y) - y))^2)) # Here we use the proxy from Svetunkov et al. (2018)
    );

    yFitted <- switch(distribution,
                      "dfnorm" = sqrt(2/pi)*scale*exp(-mu^2/(2*scale^2))+mu*(1-2*pnorm(-mu/scale)),
                      "dnorm" =,
                      "dlaplace" =,
                      "dalaplace" =,
                      "dlogis" =,
                      "dt" =,
                      "ds" =,
                      "dpois" =,
                      "dnbinom" = mu,
                      "dchisq" = mu + df,
                      "dlnorm" = exp(mu),
                      "pnorm" = pnorm(mu, mean=0, sd=1),
                      "plogis" = plogis(mu, location=0, scale=1)
    );

    errors <- switch(distribution,
                     "dbeta" = y - yFitted,
                     "dfnorm" =,
                     "dlaplace" =,
                     "dalaplace" =,
                     "dlogis" =,
                     "dt" =,
                     "ds" =,
                     "dnorm" =,
                     "dpois" =,
                     "dnbinom" = y - mu,
                     "dchisq" = sqrt(y) - sqrt(mu),
                     "dlnorm"= log(y) - mu,
                     "pnorm" = qnorm((y - pnorm(mu, 0, 1) + 1) / 2, 0, 1),
                     "plogis" = log((1 + y * (1 + exp(mu))) / (1 + exp(mu) * (2 - y) - y)) # Here we use the proxy from Svetunkov et al. (2018)
    );

    # Relative importance of variables
    importance <- cbind(1,pICWeights %*% variablesCombinations);
    colnames(importance) <- variablesNames;

    # Some of the variables have partial inclusion, 1 stands for constant
    # This is the dynamic degrees of freedom
    df <- obsInsample - apply(importance,1,sum) - 1;

    # Calcualte logLik. This is approximate and is based on the IC weights
    logLikCombined <- logLik(ourModel);
    attr(logLikCombined,"df") <- mean(df);
    logLikCombined[1] <- colSums(pointLiks) %*% pICWeightsMean;

    # Dynamic weighted mean pAIC
    ICValue <- apply(pICWeights * pICs,1,sum);

    # Models SE
    parametersSECombined <- pICWeights %*% sqrt(parametersSE +(parameters - matrix(parametersMean,nrow(parameters),ncol(parameters),byrow=T))^2);
    colnames(parametersSECombined) <- variablesNames;

    if(any(is.nan(parametersSECombined)) | any(is.infinite(parametersSECombined))){
        warning("The standard errors of the parameters cannot be produced properly. It seems that we have overfitted the data.", call.=FALSE);
    }

    finalModel <- list(coefficients=parametersMean, se=parametersSECombined, fitted.values=as.vector(yFitted),
                       residuals=as.vector(errors), distribution=distribution, logLik=logLikCombined, IC=ICValue,
                       df.residual=mean(df), df=sum(apply(importance,2,mean))+1, importance=importance,
                       call=cl, rank=nVariables+1, data=listToCall$data, mu=mu, scale=scale,
                       coefficientsDynamic=parametersWeighted, df.residualDynamic=df, dfDynamic=apply(importance,1,sum)+1);

    return(structure(finalModel,class=c("greyboxD","alm","greybox")));
}
