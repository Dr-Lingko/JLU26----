clear; clc;

projectDir = fileparts(mfilename("fullpath"));
dataFile = fullfile(projectDir, "题目", "B题附表1至6.xlsx");
outDir = fullfile(projectDir, "output");
if ~exist(outDir, "dir")
    mkdir(outDir);
end

%% Read source tables
roadRaw = readcell(dataFile, "Sheet", "附表 1");
rainRaw = readcell(dataFile, "Sheet", "附表 2");
obsRaw = readcell(dataFile, "Sheet", "附表 4");

roadId = string(roadRaw(3:10, 1));
lenM = cell2mat(roadRaw(3:10, 2));
roadType = string(roadRaw(3:10, 4));
slopePermil = cell2mat(roadRaw(3:10, 5));
pipeDiameterMm = cell2mat(roadRaw(3:10, 6));
drainageLps = cell2mat(roadRaw(3:10, 7));  % Design drainage capacity, unit: L/s.
minElevationM = cell2mat(roadRaw(3:10, 8));

rain5min = cell2mat(rainRaw(3, 2:13));
rain15min = [sum(rain5min(1:3)), sum(rain5min(4:6)), ...
             sum(rain5min(7:9)), sum(rain5min(10:12))];
cumRainNorm = cumsum(rain15min) ./ sum(rain15min);
time15 = [15, 30, 45, 60];
time5 = 5:5:60;

obsRoadId = string(obsRaw(3:10, 1));
obsDepth = cell2mat(obsRaw(3:10, 2:5));
if any(obsRoadId ~= roadId)
    error("Road order differs between Sheet 1 and Sheet 4.");
end

%% Feature construction
psi = 0.95 * ones(size(roadId));
psi(roadType == "水泥") = 0.90;

Lnorm = lenM ./ max(lenM);
Qnorm = drainageLps ./ max(drainageLps);
Gnorm = slopePermil ./ max(slopePermil);
Enorm = (max(minElevationM) - minElevationM) ./ ...
        (max(minElevationM) - min(minElevationM));

%% Calibrate dynamic drainage model
% params = [rho_1, ..., rho_8, theta_1, ..., theta_8,
%           mu_1, ..., mu_8, delta_1, ..., delta_8]
% rho_i is the road-specific water retention coefficient; theta_i is the
% response to current rainfall; mu_i is the delayed concentration effect of
% cumulative rainfall; delta_i is the effective drainage reduction of road
% segment i during one 15-min time step.
nRoad = numel(roadId);
modelFun = @(p) simulateDepth(p, rain15min, cumRainNorm, psi);
residualFun = @(p) reshape(modelFun(p) - obsDepth, [], 1);

lb = [zeros(1, nRoad), zeros(1, nRoad), zeros(1, nRoad), zeros(1, nRoad)];
ub = [0.99 * ones(1, nRoad), 3 * ones(1, nRoad), ...
    40 * ones(1, nRoad), 30 * ones(1, nRoad)];

rng(20260502);
rho0 = 0.5 * ones(1, nRoad);
theta0 = obsDepth(:, 1)' ./ (rain15min(1) .* psi');
mu0 = zeros(1, nRoad);
delta0 = zeros(1, nRoad);
starts = [
    rho0, theta0, mu0, delta0
    0.3 * ones(1, nRoad), theta0 * 0.8, 4 * ones(1, nRoad), delta0 + 1
    0.7 * ones(1, nRoad), theta0 * 0.6, 8 * ones(1, nRoad), delta0 + 2
    rand(800, 4 * nRoad) .* [0.95 * ones(1, nRoad), ...
    1.5 * ones(1, nRoad), 20 * ones(1, nRoad), 12 * ones(1, nRoad)]
];

opts = optimoptions("lsqnonlin", ...
    "Display", "off", ...
    "MaxFunctionEvaluations", 20000, ...
    "MaxIterations", 2000, ...
    "FunctionTolerance", 1e-10, ...
    "StepTolerance", 1e-10);

bestSse = inf;
bestParam = [];
bestResidual = [];
for i = 1:size(starts, 1)
    [p, resnorm, residual] = lsqnonlin(residualFun, starts(i, :), lb, ub, opts);
    if resnorm < bestSse
        bestSse = resnorm;
        bestParam = p;
        bestResidual = residual;
    end
end

fitDepth = modelFun(bestParam);
baseResidual = fitDepth - obsDepth;
baseSse = sum(baseResidual(:).^2);
baseRmse = sqrt(mean(baseResidual(:).^2));
baseMae = mean(abs(baseResidual(:)));
baseR2 = 1 - baseSse / sum((obsDepth(:) - mean(obsDepth(:))).^2);

correction = fitResidualCorrection(obsDepth - fitDepth);
correctedDepth = max(0, fitDepth + correction);
correctedResidual = correctedDepth - obsDepth;
correctedSse = sum(correctedResidual(:).^2);
correctedRmse = sqrt(mean(correctedResidual(:).^2));
correctedMae = mean(abs(correctedResidual(:)));
correctedR2 = 1 - correctedSse / sum((obsDepth(:) - mean(obsDepth(:))).^2);
finalDepth = correctedDepth;

%% Map depth to traffic capacity and safety score
[capacity, safety] = mapTrafficState(finalDepth);

fit5 = interp1([0, time15], [zeros(numel(roadId), 1), finalDepth]', time5, "linear")';
[capacity5, safety5] = mapTrafficState(fit5);

%% Export result workbook
resultFile = fullfile(outDir, "第一问_积水动态演化结果_改进.xlsx");
if exist(resultFile, "file")
    delete(resultFile);
end

paramTable = table(baseSse, baseRmse, baseMae, baseR2, ...
    correctedSse, correctedRmse, correctedMae, correctedR2, ...
    'VariableNames', {'base_SSE', 'base_RMSE_cm', 'base_MAE_cm', 'base_R2', ...
    'corrected_SSE', 'corrected_RMSE_cm', 'corrected_MAE_cm', 'corrected_R2'});
writetable(paramTable, resultFile, "Sheet", "参数拟合");

roadFeatureTable = table(roadId, lenM, roadType, slopePermil, pipeDiameterMm, ...
    drainageLps, minElevationM, psi, Lnorm, Qnorm, Gnorm, Enorm, ...
    bestParam(1:nRoad)', bestParam(nRoad + 1:2 * nRoad)', ...
    bestParam(2 * nRoad + 1:3 * nRoad)', ...
    bestParam(3 * nRoad + 1:4 * nRoad)', ...
    'VariableNames', {'路段编号', '长度_m', '路面类型', '地形坡度_千分', ...
    '排水管网管径_mm', '设计排水能力_Lps', '最低标高_m', '径流系数', ...
    '长度归一化', '排水能力归一化', '坡度归一化', '低洼程度', ...
    '滞蓄系数rho', '当前降雨响应theta', '累积汇水响应mu', ...
    '等效排水削减delta_cm'});
writetable(roadFeatureTable, resultFile, "Sheet", "路段特征");

depthTable = makeWideTable(roadId, time15, finalDepth, "h_cm_");
capacityTable = makeWideTable(roadId, time15, capacity, "K_");
safetyTable = makeWideTable(roadId, time15, safety, "S_");
obsTable = makeWideTable(roadId, time15, obsDepth, "H_obs_cm_");
residualTable = makeWideTable(roadId, time15, correctedResidual, "error_cm_");
baseResidualTable = makeWideTable(roadId, time15, baseResidual, "base_error_cm_");
modelDepthTable = makeWideTable(roadId, time15, correctedDepth, "h_model_cm_");
baseDepthTable = makeWideTable(roadId, time15, fitDepth, "h_base_cm_");

writetable(depthTable, resultFile, "Sheet", "15min最终积水深度");
writetable(capacityTable, resultFile, "Sheet", "15min通行能力");
writetable(safetyTable, resultFile, "Sheet", "15min安全度");
writetable(obsTable, resultFile, "Sheet", "观测深度");
writetable(modelDepthTable, resultFile, "Sheet", "模型拟合深度");
writetable(baseDepthTable, resultFile, "Sheet", "基础模型深度");
writetable(residualTable, resultFile, "Sheet", "拟合误差");
writetable(baseResidualTable, resultFile, "Sheet", "基础模型误差");
writetable(makeWideTable(roadId, time5, fit5, "h_cm_"), resultFile, "Sheet", "5min积水深度插值");
writetable(makeWideTable(roadId, time5, capacity5, "K_"), resultFile, "Sheet", "5min通行能力插值");
writetable(makeWideTable(roadId, time5, safety5, "S_"), resultFile, "Sheet", "5min安全度插值");

%% Risk identification
riskText = strings(numel(roadId), 1);
maxDepth = max(finalDepth, [], 2);
for i = 1:numel(roadId)
    if maxDepth(i) >= 30
        riskText(i) = "完全中断风险";
    elseif maxDepth(i) >= 20
        riskText(i) = "高风险";
    elseif maxDepth(i) >= 10
        riskText(i) = "中风险";
    else
        riskText(i) = "低风险";
    end
end
riskTable = table(roadId, maxDepth, riskText, ...
    'VariableNames', {'路段编号', '最大拟合积水深度_cm', '风险判断'});
writetable(riskTable, resultFile, "Sheet", "风险识别");

fprintf("Results written to:\n%s\n", resultFile);

%% Local functions
function h = simulateDepth(p, rain, cumRainNorm, psi)
    nRoad = numel(psi);
    rho = p(1:nRoad)';
    theta = p(nRoad + 1:2 * nRoad)';
    mu = p(2 * nRoad + 1:3 * nRoad)';
    delta = p(3 * nRoad + 1:4 * nRoad)';
    nTime = numel(rain);
    h = zeros(nRoad, nTime);
    prev = zeros(nRoad, 1);
    for k = 1:nTime
        runoff = psi .* (theta .* rain(k) + mu .* cumRainNorm(k));
        current = max(0, rho .* prev + runoff - delta);
        h(:, k) = current;
        prev = current;
    end
end

function [capacity, safety] = mapTrafficState(depth)
    capacity = zeros(size(depth));
    safety = zeros(size(depth));

    idx = depth < 5;
    capacity(idx) = 1.0;
    safety(idx) = 1.0;

    idx = depth >= 5 & depth < 10;
    capacity(idx) = 0.8;
    safety(idx) = 0.9;

    idx = depth >= 10 & depth < 20;
    capacity(idx) = 0.4;
    safety(idx) = 0.6;

    idx = depth >= 20 & depth < 30;
    capacity(idx) = 0.1;
    safety(idx) = 0.2;

    idx = depth >= 30;
    capacity(idx) = 0.0;
    safety(idx) = 0.0;
end

function correction = fitResidualCorrection(residual)
    [nRoad, nTime] = size(residual);
    nObs = nRoad * nTime;
    X = zeros(nObs, nRoad + nTime);
    y = zeros(nObs, 1);
    row = 0;
    for i = 1:nRoad
        for k = 1:nTime
            row = row + 1;
            X(row, i) = 1;
            X(row, nRoad + k) = 1;
            y(row) = residual(i, k);
        end
    end
    coef = pinv(X) * y;
    roadBias = coef(1:nRoad);
    timeBias = coef(nRoad + 1:end);
    correction = roadBias + timeBias';
end

function T = makeWideTable(roadId, times, values, prefix)
    T = table(roadId, 'VariableNames', {'路段编号'});
    for j = 1:numel(times)
        T.(char(prefix + string(times(j)) + "min")) = values(:, j);
    end
end
