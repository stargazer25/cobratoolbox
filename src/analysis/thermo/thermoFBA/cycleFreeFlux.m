function V1 = cycleFreeFlux(V0, C, model, SConsistentRxnBool, param)
% Removes stoichiometrically balanced cycles from FBA solutions when
% possible.
%
% A Matlab implementation of the CycleFreeFlux algorithm from Desouki et
% al., 2015. Minimises the one norm of fluxes subject to bounds determined
% by input flux.
%
% USAGE:
%
%    V1 = cycleFreeFlux(V0, C, model, SConsistentRxnBool, relaxBounds);
%
% INPUTS:
%    V0:       `n x k` matrix of `k` FBA solutions
%    C:        `n x k` matrix of `k` FBA objectives
%    model:    COBRA model structure with required fields:
%
%                * .S  - `m x n` stoichiometric matrix
%                * .b  - `m x 1` RHS vector
%                * .lb - `n x 1` lower bound vector
%                * .ub - `n x 1` lower bound vector
%
% OPTIONAL INPUTS:
%    SConsistentRxnBool:    `n x 1` logical array. True for internal reactions.
%    relaxBounds:      Relax bounds that don't include zero. Default is false.
%    parallelize:      Turn parfor use on or off. Default is true if k > 12.
%
% OUTPUT:
%    V1:    `n x k` matrix of cycle free flux vectors
%
% EXAMPLE:
%    % Remove cycles from a single flux vector
%    solution = optimizeCbModel(model);
%    v1 = cycleFreeFlux(solution.v, model.c, model);
% 
%    % Remove cycles from multiple flux vectors
%    [minFlux, maxFlux, Vmin, Vmax] = fluxVariability(model, 0, 'max', model.rxns, 0, 1, 'FBA');
%    V0 = [Vmin, Vmax];
%    n = size(model.S, 2);
%    C = [eye(n), eye(n)];
%    V1 = cycleFreeFlux(V0, C, model);
%
% .. Author: - Hulda S. Haraldsdottir, 25/5/2018

if ~exist('SConsistentRxnBool', 'var') || isempty(SConsistentRxnBool) % Set defaults
    if isfield(model, 'SIntRxnBool')
        SConsistentRxnBool = model.SIntRxnBool;
    else
        tmp = model;
        tmp.c(:) = 0;
        
        if isfield(tmp, 'biomassRxnAbbr')
            tmp = rmfield(tmp, 'biomassRxnAbbr');
        end
        
        [~, SConsistentRxnBool] = findStoichConsistentSubset(tmp, 0, 0);
        
        clear tmp
    end
end



if ~exist('param','var')
    param = struct();
end

if ~isfield(param,'relaxBounds')
    param.relaxBounds = false;
end

if isfield(param,'parallelize')
    parallelize=param.parallelize;
else
    parallelize = false;
end

if ~isfield(param,'eta')
    feasTol = getCobraSolverParams('LP', 'feasTol');
    param.eta = feasTol*10;
end

if ~isfield(param,'debug')
    param.debug = 0;
end

if isfield(param,'printLevel')
    printLevel=param.printLevel;
else
    printLevel = 0;
end

k = size(V0, 2);

if param.debug
    %check the bounds on the model
    if any(model.lb>model.ub)
        error('Model Lower bounds cannot be greater than upper bounds')
    end

    %double check to see if the model admits a steady state flux
    solution = optimizeCbModel(model);
    if solution.stat~=1
        error('Model does not admit a steady state flux')
    end
    
    %check if the bounds are ok.
    for i=1:k
        if k>1
        disp(i)
        end
        v0 = V0(:, i);
        
        %check if the solution provided is an accurate steady state
        res = norm(model.S*v0 - model.b,inf);
        if res>param.eta
            error('Solution provided is not a steady state')
        end
        
        bool_ub = v0 > model.ub;
        if any(bool_ub)
            bool_ub2 = v0 > model.ub + param.eta;
            if any(bool_ub2)
                model.rxns(bool_ub)
                error(['Input flux vector majorly violated upper bounds, in ' int2str(i) 'th flux vector'])
            else
                if printLevel>0
                    warning('Input flux vector minorly violated upper bounds, setting some input fluxes to ub.')
                end
                V0(bool_ub,i) = model.ub(bool_ub);
            end
        end
        bool_lb = model.lb > V0;
        if any(bool_ub)
            
            bool_lb2 = model.lb - param.eta > V0;
            if any(bool_lb2)
                model.rxns(bool_lb)
                error(['Input flux vector  solution majorly violated lower bounds, in ' int2str(i) 'th flux vector'])
            else
                if printLevel>0
                    warning('Input flux vector solution minorly violated lower bounds, setting some input fluxes to lb.')
                end
                V0(bool_lb,i) = model.lb(bool_lb);
            end
        end

    end
end

% Check for parallel computing toolbox
try
    gcp('nocreate');
    hasPCT = true;
catch
    hasPCT = false;
end

if ~exist('parallelize', 'var') || isempty(parallelize)
    if hasPCT && k > 12
        parallelize = true;
    else
        parallelize = false;
    end
end

% parameters
[model_S, model_b, model_lb, model_ub] = deal(model.S, model.b, model.lb, model.ub);

[~,osense] = getObjectiveSense(model);

% loop through input flux vectors
V1 = zeros(size(V0));

param.printLevel=printLevel-1;
if parallelize
    environment = getEnvironment();
    parfor i = 1:k
        restoreEnvironment(environment,0);
        
        v0 = V0(:, i);
        c0 = C(:, i);
        
        try
            v1 = computeCycleFreeFluxVector(v0, c0, osense, model_S, model_b, model_lb, model_ub, SConsistentRxnBool, param); % see subfunction below
            V1(:, i) = v1;
        catch 
            v2 = computeCycleFreeFluxVector(v0, c0, osense, model_S, model_b, model_lb, model_ub, SConsistentRxnBool, param); % see subfunction below
            V1(:, i) = v2;
            fprintf('%s\n','computeCycleFreeFluxVector: infeasible problem without relaxation of positive lower bounds and negative upper bounds')
        end
    end
    
else
    for i = 1:k
        v0 = V0(:, i);
        c0 = C(:, i);
        
        try
            v1 = computeCycleFreeFluxVector(v0, c0, osense, model_S, model_b, model_lb, model_ub, SConsistentRxnBool, param); % see subfunction below
        catch ME
            if param.relaxBounds==0
                disp(ME.message)
                param.relaxBounds=1;
                v1 = computeCycleFreeFluxVector(v0, c0, osense, model_S, model_b, model_lb, model_ub, SConsistentRxnBool, param); % see subfunction below
                fprintf('%s\n','computeCycleFreeFluxVector: infeasible problem without relaxation of positive lower bounds and negative upper bounds')
            else
                rethrow(ME)
            end
        end
        V1(:, i) = v1;
        
    end
end

end

function v1 = computeCycleFreeFluxVector(v0, c0, osense, model_S, model_b, model_lb, model_ub, SConsistentRxnBool, param)

%by default, do not remove fixed variables, let the solver deal with them
removeFixedBool = 0;

feasTol = getCobraSolverParams('LP', 'feasTol');
epsilon = feasTol*10;
if any(model_ub-model_lb<feasTol & model_ub~=model_lb)
    warning('cycleFreeFlux: Unperturbed lower and upper bounds closer than feasibility tolerance. May cause numerical issues.')
end
    
%adaption to deal with infeasibility due to numerical imprecision
%https://cran.r-project.org/web/packages/sybilcycleFreeFlux/index.html
if 0

    model_lb = model_lb -epsilon/2;
    model_ub = model_ub + epsilon/2;
end

[m,n] = size(model_S);
p = sum(SConsistentRxnBool);

D = sparse(p, n);
D(:, SConsistentRxnBool) = speye(p);


isF = [SConsistentRxnBool & v0 > 0; false(p,1)]; % net forward flux
isR = [SConsistentRxnBool & v0 < 0; false(p,1)]; % net reverse flux

% objective: minimize one-norm
c = [zeros(n, 1); ones(p, 1)]; % variables: [v; x]

% constraints
%       v            x
A = [...
    model_S   sparse(m, p); % Sv = b (steady state)
    c0'       sparse(1, p); % c0'v = c0'v0
    D        -speye(p)    ; %   v - x <= 0
   -D        -speye(p)   ]; % - v - x <= 0


b = [model_b;  c0' * v0; zeros(2*p, 1)];

csense = repmat('E', size(A, 1), 1);
csense(m+2:end) = 'L';

%this approach is more numerically robust than forcing the new objective to equal the
%previous objective
if osense == 1
    csense(m+1) = 'L';
else
    csense(m+1) = 'G';
end

% bounds
lb = [v0; zeros(p, 1)]; % fixed exchange fluxes
if param.relaxBounds
    lb(isF) = 0; % internal reaction directionality same as in input flux
else
    lb(isF) = max(0,model_lb(isF)); % Keep lower bound if it is > 0 (forced positive flux)
end


ub = [v0; abs(v0(SConsistentRxnBool))+epsilon];

if param.relaxBounds
    ub(isR) = 0;
else
    ub(isR) = min(0,model_ub(isR)); % Keep upper bound if it is < 0 (forced negative flux)
end

if any(lb(1:n)>ub(1:n))
    if norm(lb(lb(1:n)>ub(1:n))-ub(lb(1:n)>ub(1:n)),inf)<1e-9
        lb(lb(1:n)>ub(1:n))=ub(lb(1:n)>ub(1:n));
        if param.printLevel>0
            fprintf('%s\n','Lower bounds slightly greater than upper bounds, set to the same.')
        end
    else
        error('Lower bounds cannot be greater than upper bounds')
    end
end

if any(lb(n+1:n+p)>ub(n+1:n+p))
    error('Lower bounds cannot be greater than upper bounds')
end


%relax bounds on non fixed variables
bool = ub-lb<feasTol & ub~=lb;
lb(bool)=lb(bool)-feasTol*10;
ub(bool)=ub(bool)+feasTol*10;

if param.debug
    if any(ub-lb<feasTol & ub~=lb)
        fprintf('%s\n','cycleFreeFlux: Perturbed lower and upper bounds closer than feasibility tolerance, this could cause numerical issues.')
    end
end

if any(lb>ub)
    error('Lower bounds cannot be greater than upper bounds')
end

lp = struct('osense', 1, 'c', c, 'A', A, ...
    'csense', csense, 'b', b, 'lb', lb, 'ub', ub);

if removeFixedBool
    % net zero flux
    isZero = SConsistentRxnBool & v0 == 0; 
    %remove the fixed variables from the problem
    zeroBool = [isZero; false(p,1)];
    if 0
        fixedBool = lp.lb == lp.ub | zeroBool;
    else
        %assume the external reactions are also fixed
        fixedBool = lp.lb == lp.ub | zeroBool | [~SConsistentRxnBool;false(p,1)];
    end
else
    fixedBool=0;
end

if any(fixedBool)
      lp.b = lp.b - lp.A(:,fixedBool)*lp.lb(fixedBool);
      lp.A = lp.A(:,~fixedBool);
      lp.lb = lp.lb(~fixedBool);
      lp.ub = lp.ub(~fixedBool);
      lp.c = lp.c(~fixedBool);
end

% solve LP
solution = solveCobraLP(lp);

if solution.stat == 1
    
    if any(fixedBool)
        %rebuild optimal flux vector
        full = zeros(n+p,1);
        full(fixedBool)=lb(fixedBool);
        full(~fixedBool)=solution.full;
        solution.full = full;
    end

    v1 = solution.full(1:n);
else
    %debugging=1;
    if param.debug
       norm(model_S*v0-model_b,'inf')
       
       belowLowerBound = v0-model_lb;
       belowLowerBound(belowLowerBound>0)=0;
       min(belowLowerBound)
       
       aboveUpperBound = model_ub-v0;
       aboveUpperBound(aboveUpperBound>0)=0;
       min(aboveUpperBound)
       
        solution
        
        lpRelaxed = lp;
        lpRelaxed.ub = lp.ub + feasTol*10;
        lpRelaxed.lb = lp.lb - feasTol*10;
        solutionRelaxed1 = solveCobraLP(lpRelaxed)
        
        lpRelaxed.lb(:) = -10;
        lpRelaxed.ub(:) =  10;
        solutionRelaxed2 = solveCobraLP(lpRelaxed)
        
        lpRelaxed.lb(:) = -inf;
        lpRelaxed.ub(:) =  inf;
        solutionRelaxed3 = solveCobraLP(lpRelaxed)
    end
    fprintf('%s\n%sn','cycleFreeFlux: No solution found.','Try using a different solver');
    error('cycleFreeFlux: No solution found, try using a different solver');
end

end

