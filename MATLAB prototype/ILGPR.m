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
            obj.newLGPCutoff = 0.1;
            obj.M = 10;
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
        
        function [weightedZ,weightedS] = predict(self,x)
                
            numStarted = 0;
            validLGPIdx = [];
            for j=1:self.nLGPs
                if self.LGPs{j}.isStarted()
                    numStarted = numStarted + 1;
                    validLGPIdx = [validLGPIdx j];
                end
            end

            if numStarted > self.M
                numStarted = self.M;
            end
            if ~numStarted
                disp('WARNING: No started LGPs available for prediction');
                return;
            end
            
            self.updateStartedLGPMCs();
            self.mcfSum = 0;
            for j=1:self.nLGPs                
                if self.LGPs{j}.isStarted()
                    self.LGPs{j}.updateF(x);
                    self.mcfSum = self.mcfSum + self.LGPs{j}.getMC()*self.LGPs{j}.getF();
                end
            end                
            
            weights = zeros(numStarted,1);
            for j = 1:self.nLGPs
                weights(j) = self.LGPs{j}.getMC()*self.LGPs{j}.getF()/self.mcfSum;
            end
            [sortedWeights, sorted_idx] = sort(weights,'descend');            
            
            weightedZ = 0;
            weightedS = 0;
%             for j=1:self.nLGPs
            for j = sorted_idx'
                if self.LGPs{j}.isStarted() % no need to calculate unless it is started (because weight would be zero anyway)
%                     weightedZ = weightedZ + self.LGPs{j}.getMC()*self.LGPs{j}.getF()*self.LGPs{j}.predict(x)/self.mcfSum;
                    [zHat,sHat] = self.LGPs{j}.predict(x);
                    weightedZ = weightedZ + zHat*weights(j);
                    weightedS = weightedS + sHat*weights(j);
                end
            end
            self.updateMCs(); % revert back to the mixture coefficients of all LGPs, not just the started ones
            self.updateMCFSum(); % revert back to the mcf sum with all LGPs, not just the started ones

%             % calculate likelihood for all LGPs
%             likelihoods = zeros(numStarted,1);
%             likelihoodsIdx = zeros(numStarted,1);
%             for i = 1:numStarted
%                 validIndex = validLGPIdx(i);
%                 self.LGPs{validIndex}.updateF(x.getX());
%                 likelihoods(i) = self.LGPs{validIndex}.getF();
%                 likelihoodsIdx(i) = validIndex;
%             end
% 
%             % M closest local models, user-defined.
%             [sortedValues, sortIndex] = sort(likelihoods,'descend');
% 
%             predictY = zeros(numStarted,1);
%             for i = 1:numStarted
%                 predictY(i) = self.LGPs{likelihoodsIdx(sortIndex(i))}.predict(x);
%                 aaa = sprintf('        LGP %d predicts %f ... length scales = %f, %f ... process variance = %f \n',likelihoodsIdx(sortIndex(i)),predictY(i),...
%                     exp(self.LGPs{likelihoodsIdx(sortIndex(i))}.hyp.cov(1)),...
%                     exp(self.LGPs{likelihoodsIdx(sortIndex(i))}.hyp.cov(2)),...
%                     exp(self.LGPs{likelihoodsIdx(sortIndex(i))}.hyp.cov(3)));
%                 disp(aaa);
%             end
%             weightedZ = sortedValues(1:numStarted)'*predictY/sum(sortedValues(1:numStarted));
            
%             % for testing
%             display(likelihoods);
%             display(likelihoodsIdx);
%             display(predictY);
%             display(sortedValues);
%             display(sortIndex);
%             display(numStarted);
%             display(x);
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