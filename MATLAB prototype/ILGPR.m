classdef ILGPR < handle
    
    %{
        
    %}
    
    properties
        LGPs % vector of LGP objects
        nLGPs % number of LGPs
        predictionX % grid of prediction locations
        predictionZ % avg. at prediction X
        predictionS % std dev. at prediction X
        spSum % sum of LGP's activations
        mcfSum % sum of mixture components
        newLGPCutoff % likelihood below which a new LGP will be added
        M % the maximum number of LGP models used in the prediction
    end
    
    methods
        function obj = ILGPR(predictionX, predictionZ, predictionS)
            obj.nLGPs = 0;
            obj.LGPs = cell(1,1);
            obj.predictionX = predictionX;
            obj.predictionZ = predictionZ;
            obj.predictionS = predictionS;
            obj.spSum = 0;
            obj.newLGPCutoff = 0.9; % if the best LGP has nothing better than a 50/50 shot, generate a new LGP
            obj.M = 5;
        end       
        
        function newDatum(self,Datum)
            if self.nLGPs > 0 % there is at least one LGP
                likelihoods = zeros(self.nLGPs,1);
                
                % calculate likelihood for all LGPs
                for i = 1:self.nLGPs
                    self.LGPs{i}.updateF(Datum.getX());
                    likelihoods(i) = self.LGPs{i}.getF();
                end                
                
                [maxLikelihood,bestLGPIdx] = max(likelihoods);
                                
                if maxLikelihood > self.newLGPCutoff
                    updateMCFSum(self); % update sum of mixture coefficient*likelihood, used to find the posterior
                    
                    % calculate posterior for all LGPs
                    posteriors = zeros(self.nLGPs,1);
                    for i = 1:self.nLGPs
                        posterior = self.LGPs{i}.getMC()*self.LGPs{i}.getF()/self.mcfSum;
                        posteriors(i) = posterior;
                        self.LGPs{i}.updateSP(posterior);
                    end
                    updateMCs(self);                                        
                    updateCenters(self,Datum,posteriors);
                    
                    % add Datum to LGP with maximum likelihood (not max posterior)                    
                    self.LGPs{bestLGPIdx}.newDatum(Datum);
                    
                else % the max likelihood is too small, need new LGP 
                    addLGP(self,Datum);
                    updateMCs(self);
                end
                
            else % the first LGP
                addLGP(self,Datum);
                updateMCs(self);
            end            
        end
        
        function addLGP(self,Datum)
            self.nLGPs = self.nLGPs + 1;
            newLGP = LGP(self.nLGPs,Datum);            
            self.LGPs{self.nLGPs} = newLGP;
        end        
        
        function weightedZ = predict(self,x)             
            numStarted = 0;
            validLGPIdx = [];
            
            for j=1:self.nLGPs
                if self.LGPs{j}.isStarted()
                    numStarted = numStarted + 1;
                    validLGPIdx = [validLGPIdx j];
                end
            end

            if numStarted > self.M
                numPredictLGP = self.M;
            else
                numPredictLGP = numStarted;
            end
            if ~numStarted
                disp('WARNING: No started LGPs available for prediction');
                return;
            end

            % calculate likelihood for all LGPs
            likelihoods = zeros(numStarted,1);
            likelihoodsIdx = validLGPIdx;
            for i = 1:numStarted
                validIndex = likelihoodsIdx(i);
                self.LGPs{validIndex}.updateF(x.getX());
                likelihoods(i) = self.LGPs{validIndex}.getF();
            end

            % M closest local models, user-defined.
            [sortedlikelihoods, sortlikelihoodsIdx] = sort(likelihoods,'descend');

            predictY = zeros(numPredictLGP,1);
            sortedMC = zeros(numPredictLGP,1); % pi_k in paper
            sortedF = sortedlikelihoods(1:numPredictLGP); % w_k in paper
            for i = 1:numPredictLGP
                predictY(i) = self.LGPs{likelihoodsIdx(sortlikelihoodsIdx(i))}.predict(x.getX());   
                sortedMC(i) = self.LGPs{likelihoodsIdx(sortlikelihoodsIdx(i))}.getMC();
            end
            
            % Clustering to filter the outlier prediction data
            % Assuming only few outliers, so choose k=2
            clusteringIdx = kmeans(predictY,2);
            if sum(clusteringIdx==1) > sum(clusteringIdx==2)
                ultimateIdx = (clusteringIdx==1);
            else
                ultimateIdx = (clusteringIdx==2);
            end
            
            sortedMCF = sortedMC(ultimateIdx).*sortedF(ultimateIdx); % pi_k*w_k, coefficient before \hat{y_k}
            weightedZ = sortedMCF'*predictY(ultimateIdx)/sum(sortedMCF);
        end
        
        function updateCenters(self,Datum,posteriors)
            for i = 1:self.nLGPs
                self.LGPs{i}.updateCenter(Datum.getX(),posteriors(i));
            end
        end
        
        function updateStartedLGPMCs(self) % find mixture coefficients of just the started LGPs       
            startedSPSum = 0;
            for j = 1:self.nLGPs
                if self.LGPs{j}.isStarted
                    startedSPSum = startedSPSum + self.LGPs{j}.getSP();
                end                
            end
            for j = 1:self.nLGPs
                if self.LGPs{j}.isStarted
                    self.LGPs{j}.setMC(self.LGPs{j}.getSP()/startedSPSum);
                else
                    self.LGPs{j}.setMC(0);
                end
            end
        end
        
        function updateMCs(self)
            updateSPSum(self);
            for i = 1:self.nLGPs
                self.LGPs{i}.setMC(self.LGPs{i}.getSP()/self.spSum);
            end               
        end
        
        function updateSPSum(self)
            self.spSum = 0;
            for i = 1:self.nLGPs
                self.spSum = self.spSum + self.LGPs{i}.getSP();
            end            
        end
        
        function updateMCFSum(self)
            self.mcfSum = 0;
            for i = 1:self.nLGPs
                self.mcfSum = self.mcfSum + self.LGPs{i}.getMC()*self.LGPs{i}.getF();
            end
        end        
     
    end
    
end