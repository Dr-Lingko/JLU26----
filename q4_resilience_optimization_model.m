clear; clc;

projectDir = fileparts(mfilename("fullpath"));
dataFile = fullfile(projectDir, "题目", "B题附表1至6.xlsx");
outDir = fullfile(projectDir, "output");
if ~exist(outDir, "dir")
    mkdir(outDir);
end

%% Read current resilience indicators from Sheet 5
raw5 = readcell(dataFile, "Sheet", "附表 5");
primary = string(raw5(3:11, 1));
secondary = string(raw5(3:11, 2));
unitName = string(raw5(3:11, 3));
currentValue = cell2mat(raw5(3:11, 4));
idealValue = cell2mat(raw5(3:11, 5));
weight = cell2mat(raw5(3:11, 6));

for i = 2:numel(primary)
    if strlength(primary(i)) == 0 || ismissing(primary(i))
        primary(i) = primary(i - 1);
    end
end

idxDrain = find(contains(secondary, "排水能力达标率"));
idxLow = find(contains(secondary, "低洼路段占比"));
idxHalf = find(contains(secondary, "半衰期"));
idxResp = find(contains(secondary, "应急响应时间"));
idxStorage = find(contains(secondary, "绿色调蓄容积"));
idxCover = find(contains(secondary, "预警覆盖率"));

baseScore = calcCri(currentValue, idealValue, weight, secondary);

%% Decision grids and measure assumptions
% x1: 管网扩径长度(m), x2: 调蓄池数量(座), x3: 透水路面面积(m^2), x4: 预警系统数量(套)
x1Grid = (0:500:5000)';
x2Grid = (0:5)';
x3Grid = (0:5000:50000)';
x4Grid = (0:6)';

maxPipeM = 5000;
maxPavementM2 = 50000;
fullWarningSet = 6;

costPipePerM = 1.8;
costPoolPerUnit = 1200;
costPavementPerM2 = 0.35;
costWarningPerSet = 80;

pipeDrainBoost = 25;       % 表6中0.25解释为完成5000m管网后排水达标率提升25个百分点
pavementDrainBoost = 15;   % 表6中0.15解释为完成50000m2透水路面后排水达标率提升15个百分点
pipeHalfReduce = 0.15;
poolHalfReduce = 0.20;
pavementHalfReduce = 0.10;
warningRespReduce = 0.40;

%% Enumerate candidate plans
nPlan = numel(x1Grid) * numel(x2Grid) * numel(x3Grid) * numel(x4Grid);
records = cell(nPlan, 18);
row = 0;

for a = 1:numel(x1Grid)
    for b = 1:numel(x2Grid)
        for c = 1:numel(x3Grid)
            for d = 1:numel(x4Grid)
                x1 = x1Grid(a);
                x2 = x2Grid(b);
                x3 = x3Grid(c);
                x4 = x4Grid(d);

                newValue = currentValue;
                newValue(idxDrain) = min(idealValue(idxDrain), ...
                    currentValue(idxDrain) + pipeDrainBoost * x1 / maxPipeM + ...
                    pavementDrainBoost * x3 / maxPavementM2);

                % 本题表6没有给出道路抬升或低洼点改造，低洼占比保持不变。
                newValue(idxLow) = currentValue(idxLow);

                newValue(idxHalf) = max(idealValue(idxHalf), ...
                    currentValue(idxHalf) * (1 - pipeHalfReduce * x1 / maxPipeM) * ...
                    (1 - poolHalfReduce) ^ x2 * ...
                    (1 - pavementHalfReduce * x3 / maxPavementM2));

                newValue(idxResp) = max(idealValue(idxResp), ...
                    currentValue(idxResp) * (1 - warningRespReduce * x4 / fullWarningSet));

                newValue(idxStorage) = min(idealValue(idxStorage), ...
                    currentValue(idxStorage) + 800 * x2 + 0.1 * x3);

                newValue(idxCover) = min(idealValue(idxCover), ...
                    currentValue(idxCover) + (idealValue(idxCover) - currentValue(idxCover)) * ...
                    x4 / fullWarningSet);

                cri = calcCri(newValue, idealValue, weight, secondary);
                cost = costPipePerM * x1 + costPoolPerUnit * x2 + ...
                    costPavementPerM2 * x3 + costWarningPerSet * x4;
                deltaCri = cri - baseScore;
                ce = safeDivide(deltaCri, cost);

                row = row + 1;
                records(row, :) = {x1, x2, x3, x4, cost, cri, deltaCri, ...
                    newValue(idxDrain), newValue(idxLow), newValue(idxHalf), ...
                    newValue(idxResp), newValue(idxStorage), newValue(idxCover), ...
                    ce, costPipePerM * x1, costPoolPerUnit * x2, ...
                    costPavementPerM2 * x3, costWarningPerSet * x4};
            end
        end
    end
end

allPlanTable = cell2table(records, 'VariableNames', ...
    {'管网扩径_m', '调蓄池_座', '透水路面_m2', '预警系统_套', ...
    '总成本_万元', 'CRI', 'CRI提升', '排水能力达标率', '低洼路段占比', ...
    '积水消退半衰期_min', '应急响应时间_min', '绿色调蓄容积_m3', ...
    '预警覆盖率', '成本效益_CRI每万元', '管网成本_万元', '调蓄池成本_万元', ...
    '透水路面成本_万元', '预警系统成本_万元'});

%% Pareto front and recommendation
isPareto = paretoMask(allPlanTable.("总成本_万元"), allPlanTable.CRI, ...
    allPlanTable.("积水消退半衰期_min"));
paretoTable = allPlanTable(isPareto, :);
paretoTable = sortrows(paretoTable, ["总成本_万元", "CRI"], ["ascend", "descend"]);

budgetLimits = [0; 2000; 5000; 10000; 20000];
budgetNames = ["现状不改造"; "快速见效(不超过2000万元)"; ...
    "综合均衡(不超过5000万元)"; "较高预算(不超过1亿元)"; ...
    "长期提升(不超过2亿元)"];
budgetRows = cell(numel(budgetLimits), width(allPlanTable) + 2);
for i = 1:numel(budgetLimits)
    if budgetLimits(i) == 0
        plan = allPlanTable(allPlanTable.("总成本_万元") == 0, :);
        plan = plan(1, :);
    else
        feasible = allPlanTable(allPlanTable.("总成本_万元") <= budgetLimits(i), :);
        utility = 0.65 * normalizeBenefit(feasible.CRI) + ...
            0.25 * normalizeBenefit(-feasible.("积水消退半衰期_min")) + ...
            0.10 * normalizeBenefit(-feasible.("总成本_万元"));
        [~, bestIdx] = max(utility);
        plan = feasible(bestIdx, :);
    end
    budgetRows(i, :) = [{budgetNames(i), budgetLimits(i)}, table2cell(plan)];
end

budgetTable = cell2table(budgetRows, 'VariableNames', ...
    ["预算类型", "预算上限_万元", allPlanTable.Properties.VariableNames]);

% 以5000万元左右的综合均衡方案作为论文主推荐，避免推荐方案只集中于单一工程措施。
recommendedPlan = budgetTable(3, allPlanTable.Properties.VariableNames);

%% Independent marginal effect of each measure
measureRows = cell(4, 8);
singlePlans = [
    1000, 0, 0, 0
    0, 1, 0, 0
    0, 0, 10000, 0
    0, 0, 0, 1
];
measureNames = ["管网扩径1000m"; "新建调蓄池1座"; "透水路面10000m2"; "智慧预警1套"];
for i = 1:4
    p = findPlan(allPlanTable, singlePlans(i, 1), singlePlans(i, 2), ...
        singlePlans(i, 3), singlePlans(i, 4));
    measureRows(i, :) = {measureNames(i), singlePlans(i, 1), singlePlans(i, 2), ...
        singlePlans(i, 3), singlePlans(i, 4), p.("总成本_万元"), p.("CRI提升"), ...
        p.("成本效益_CRI每万元")};
end
measureTable = cell2table(measureRows, 'VariableNames', ...
    {'措施', '管网扩径_m', '调蓄池_座', '透水路面_m2', '预警系统_套', ...
    '成本_万元', 'CRI提升', '成本效益_CRI每万元'});
measureTable = sortrows(measureTable, "成本效益_CRI每万元", "descend");

%% Robustness analysis for the recommended plan
robustBase = table2array(recommendedPlan(:, {'管网扩径_m', '调蓄池_座', '透水路面_m2', '预警系统_套'}));
scenarioName = [
    "管网排水提升-20%"; "管网排水提升+20%"
    "调蓄池消退效果-20%"; "调蓄池消退效果+20%"
    "透水路面综合效果-20%"; "透水路面综合效果+20%"
    "预警响应效果-20%"; "预警响应效果+20%"
];
scenarioFactor = [
    0.8, 1, 1, 1
    1.2, 1, 1, 1
    1, 0.8, 1, 1
    1, 1.2, 1, 1
    1, 1, 0.8, 1
    1, 1, 1.2, 1
    1, 1, 1, 0.8
    1, 1, 1, 1.2
];
robustRows = cell(numel(scenarioName), 5);
baseRecommendedCri = recommendedPlan.CRI;
for i = 1:numel(scenarioName)
    criScenario = scenarioCri(robustBase, scenarioFactor(i, :), currentValue, ...
        idealValue, weight, secondary, idxDrain, idxLow, idxHalf, idxResp, ...
        idxStorage, idxCover, maxPipeM, maxPavementM2, fullWarningSet, ...
        pipeDrainBoost, pavementDrainBoost, pipeHalfReduce, poolHalfReduce, ...
        pavementHalfReduce, warningRespReduce);
    robustRows(i, :) = {scenarioName(i), criScenario, criScenario - baseRecommendedCri, ...
        abs(criScenario - baseRecommendedCri), ...
        100 * abs(criScenario - baseRecommendedCri) / baseRecommendedCri};
end
robustTable = cell2table(robustRows, 'VariableNames', ...
    {'扰动情景', '扰动后CRI', 'CRI变化', '绝对变化', '相对变化_百分比'});

%% Export workbook
resultFile = fullfile(outDir, "第四问_韧性提升优化结果.xlsx");
if exist(resultFile, "file")
    delete(resultFile);
end
writetable(allPlanTable, resultFile, "Sheet", "全部方案");
writetable(paretoTable, resultFile, "Sheet", "帕累托前沿");
writetable(budgetTable, resultFile, "Sheet", "分预算推荐");
writetable(recommendedPlan, resultFile, "Sheet", "综合推荐方案");
writetable(measureTable, resultFile, "Sheet", "单项措施成本效益");
writetable(robustTable, resultFile, "Sheet", "鲁棒性分析");

%% Figures
figure("Color", "w");
scatter(allPlanTable.("总成本_万元"), allPlanTable.CRI, 16, ...
    allPlanTable.("积水消退半衰期_min"), "filled", "MarkerFaceAlpha", 0.35);
hold on;
scatter(paretoTable.("总成本_万元"), paretoTable.CRI, 36, "r", "filled");
scatter(recommendedPlan.("总成本_万元"), recommendedPlan.CRI, 80, "k", "filled");
xlabel("总成本 (万元)");
ylabel("CRI");
title("第四问改造方案成本-韧性帕累托前沿");
cb = colorbar;
cb.Label.String = "消退半衰期 (min)";
grid on;
exportgraphics(gcf, fullfile(outDir, "第四问_帕累托前沿.png"), "Resolution", 300);

figure("Color", "w");
bar(categorical(budgetTable.("预算类型")), budgetTable.CRI);
ylabel("CRI");
ylim([0, 100]);
title("不同预算水平下的推荐方案韧性得分");
grid on;
set(gca, "XTickLabelRotation", 25);
exportgraphics(gcf, fullfile(outDir, "第四问_分预算CRI.png"), "Resolution", 300);

%% Paper-ready markdown
reportFile = fullfile(outDir, "第四问_论文表述.md");
fid = fopen(reportFile, "w", "n", "UTF-8");
fprintf(fid, "# 第四问：内涝韧性提升综合改造方案优化\n\n");
fprintf(fid, "## 1 建模思路\n\n");
fprintf(fid, "第四问在第二问内涝韧性综合评价模型基础上进行改造方案优化。附表5给出了韧性评价指标及权重，附表6给出了管网扩径、新建调蓄池、透水路面改造和智慧预警系统的成本及效果。因此，本文不再重新构造评价体系，而是将改造措施转化为附表5中相应指标的变化，并以改造后综合韧性指数 CRI、总成本和积水消退半衰期作为优化目标。\n\n");
fprintf(fid, "由于附表6未给出路网连通度、抢修覆盖效率、疏散点位密度等指标的直接改善关系，本文仅更新排水能力达标率、积水消退半衰期、应急响应时间、绿色调蓄容积和预警覆盖率，其余指标保持第二问现状值不变。第二问计算得到现状综合韧性指数为 %.2f 分。\n\n", baseScore);

fprintf(fid, "## 2 决策变量与成本函数\n\n");
fprintf(fid, "设决策变量为：\n\n");
fprintf(fid, "$$x_1: \\text{管网扩径长度(m)},\\quad x_2: \\text{新建调蓄池数量(座)},\\quad x_3: \\text{透水路面改造面积(m^2)},\\quad x_4: \\text{智慧预警系统数量(套)}.$$\n\n");
fprintf(fid, "变量取值范围为：\n\n");
fprintf(fid, "$$0\\le x_1\\le 5000,\\quad 0\\le x_2\\le 5,\\quad 0\\le x_3\\le 50000,\\quad 0\\le x_4\\le 6,$$\n\n");
fprintf(fid, "其中 \\(x_2,x_4\\) 为整数变量。总成本函数为：\n\n");
fprintf(fid, "$$C(\\mathbf{x})=1.8x_1+1200x_2+0.35x_3+80x_4,$$\n\n");
fprintf(fid, "单位为万元。\n\n");

fprintf(fid, "## 3 指标改善模型\n\n");
fprintf(fid, "表6中的排水能力提升 0.25 和 0.15 分别解释为完成 5000 m 管网扩径和 50000 m\\(^2\\) 透水路面改造后的总提升幅度，则排水能力达标率为：\n\n");
fprintf(fid, "$$D(\\mathbf{x})=\\min\\left\\{100,68+25\\frac{x_1}{5000}+15\\frac{x_3}{50000}\\right\\}.$$\n\n");
fprintf(fid, "绿色调蓄容积为：\n\n");
fprintf(fid, "$$V(\\mathbf{x})=\\min\\left\\{3500,1200+800x_2+0.1x_3\\right\\}.$$\n\n");
fprintf(fid, "积水消退半衰期采用边际递减形式描述多措施叠加效应：\n\n");
fprintf(fid, "$$T_h(\\mathbf{x})=\\max\\left\\{20,45\\left(1-0.15\\frac{x_1}{5000}\\right)(1-0.20)^{x_2}\\left(1-0.10\\frac{x_3}{50000}\\right)\\right\\}.$$\n\n");
fprintf(fid, "智慧预警系统主要改善应急响应时间和预警覆盖率：\n\n");
fprintf(fid, "$$T_r(\\mathbf{x})=\\max\\left\\{5,12\\left(1-0.40\\frac{x_4}{6}\\right)\\right\\},$$\n\n");
fprintf(fid, "$$P(\\mathbf{x})=\\min\\left\\{100,75+25\\frac{x_4}{6}\\right\\}.$$\n\n");
fprintf(fid, "将改造后的指标代入第二问评价模型：\n\n");
fprintf(fid, "$$CRI(\\mathbf{x})=100\\sum_{j=1}^{9}w_js_j(\\mathbf{x}).$$\n\n");

fprintf(fid, "## 4 多目标优化模型与求解\n\n");
fprintf(fid, "建立多目标优化模型：\n\n");
fprintf(fid, "$$\\min C(\\mathbf{x}),\\quad \\max CRI(\\mathbf{x}),\\quad \\min T_h(\\mathbf{x}).$$\n\n");
fprintf(fid, "由于决策变量数量较少，本文采用网格枚举法求解：管网扩径以 500 m 为步长，透水路面以 5000 m\\(^2\\) 为步长，调蓄池和预警系统按整数枚举，共得到 %d 个候选方案。对于任意两个方案 \\(a,b\\)，若满足\n\n", height(allPlanTable));
fprintf(fid, "$$C(a)\\le C(b),\\quad CRI(a)\\ge CRI(b),\\quad T_h(a)\\le T_h(b),$$\n\n");
fprintf(fid, "且至少一个不等式严格成立，则称方案 \\(a\\) 支配方案 \\(b\\)。不被任何其他方案支配的方案构成帕累托前沿。MATLAB 共识别出 %d 个帕累托有效方案。\n\n", height(paretoTable));

fprintf(fid, "## 5 优化结果\n\n");
fprintf(fid, "不同预算水平下的推荐方案如下：\n\n");
fprintf(fid, "| 预算类型 | 方案组合 | 成本/万元 | CRI | CRI提升 | 消退半衰期/min | 应急响应/min | 调蓄容积/m³ |\n");
fprintf(fid, "|---|---|---:|---:|---:|---:|---:|---:|\n");
for i = 1:height(budgetTable)
    fprintf(fid, "| %s | %s | %.0f | %.2f | %.2f | %.2f | %.2f | %.0f |\n", ...
        char(budgetTable.("预算类型")(i)), char(planText(budgetTable(i, :))), ...
        budgetTable.("总成本_万元")(i), budgetTable.CRI(i), budgetTable.("CRI提升")(i), ...
        budgetTable.("积水消退半衰期_min")(i), budgetTable.("应急响应时间_min")(i), ...
        budgetTable.("绿色调蓄容积_m3")(i));
end

fprintf(fid, "\n综合推荐方案为：%s。该方案总成本为 %.0f 万元，CRI 由 %.2f 提升至 %.2f，提高 %.2f 分；积水消退半衰期由 45 min 降至 %.2f min，应急响应时间由 12 min 降至 %.2f min，绿色调蓄容积提升至 %.0f m³。\n\n", ...
    char(planText(recommendedPlan)), recommendedPlan.("总成本_万元"), baseScore, ...
    recommendedPlan.CRI, recommendedPlan.("CRI提升"), ...
    recommendedPlan.("积水消退半衰期_min"), recommendedPlan.("应急响应时间_min"), ...
    recommendedPlan.("绿色调蓄容积_m3"));

fprintf(fid, "单项措施成本效益排序如下：\n\n");
fprintf(fid, "| 排名 | 措施 | 成本/万元 | CRI提升 | 成本效益/(CRI分/万元) |\n");
fprintf(fid, "|---:|---|---:|---:|---:|\n");
for i = 1:height(measureTable)
    fprintf(fid, "| %d | %s | %.0f | %.2f | %.4f |\n", i, char(measureTable.("措施")(i)), ...
        measureTable.("成本_万元")(i), measureTable.("CRI提升")(i), ...
        measureTable.("成本效益_CRI每万元")(i));
end

fprintf(fid, "\n## 6 鲁棒性分析\n\n");
fprintf(fid, "对综合推荐方案中各类措施的关键效果系数分别施加 \\(\\pm20\\%%\\) 扰动，得到 CRI 波动如下：\n\n");
fprintf(fid, "| 扰动情景 | 扰动后CRI | CRI变化 | 相对变化/%% |\n");
fprintf(fid, "|---|---:|---:|---:|\n");
for i = 1:height(robustTable)
    fprintf(fid, "| %s | %.2f | %.2f | %.2f |\n", char(robustTable.("扰动情景")(i)), ...
        robustTable.("扰动后CRI")(i), robustTable.("CRI变化")(i), ...
        robustTable.("相对变化_百分比")(i));
end
fprintf(fid, "\n鲁棒性分析表明，综合推荐方案对单项效果参数扰动不敏感，CRI 变化幅度整体较小；其中调蓄池消退效果和预警响应效果对结果影响相对更明显，说明后续实施中应优先保证调蓄设施容量和预警系统覆盖效果。\n\n");

fprintf(fid, "## 7 结论\n\n");
fprintf(fid, "第四问优化结果表明，单纯追求最高 CRI 会导致边际投入效益下降。较低预算下应优先建设智慧预警系统并配合少量调蓄设施，以快速改善应急响应和恢复能力；中等预算下，管网扩径、调蓄池和预警系统的组合能够显著提升整体韧性；高预算阶段继续增加透水路面改造可进一步提高排水和调蓄能力，但提升幅度趋于平缓。因此，建议采用分阶段实施策略：近期优先完成预警系统和调蓄设施建设，中期推进重点管网扩径，长期结合道路更新逐步扩大透水路面改造范围。\n");
fclose(fid);

fprintf("Fourth-question results written to:\n%s\n%s\n", resultFile, reportFile);
fprintf("Base CRI: %.2f\n", baseScore);
fprintf("Pareto plans: %d / %d\n", height(paretoTable), height(allPlanTable));
fprintf("Recommended plan: %s\n", char(planText(recommendedPlan)));
disp(recommendedPlan(:, {'总成本_万元', 'CRI', 'CRI提升', '积水消退半衰期_min', '应急响应时间_min', '绿色调蓄容积_m3'}));
disp(budgetTable(:, {'预算类型', '总成本_万元', 'CRI', 'CRI提升', '积水消退半衰期_min'}));

%% Local functions
function cri = calcCri(value, idealValue, weight, secondary)
    score = zeros(size(weight));
    for j = 1:numel(weight)
        name = secondary(j);
        if contains(name, "低洼路段占比")
            score(j) = 1 - value(j) / 100;
        elseif contains(name, "半衰期") || contains(name, "时间")
            score(j) = idealValue(j) / value(j);
        else
            score(j) = value(j) / idealValue(j);
        end
        score(j) = min(max(score(j), 0), 1);
    end
    cri = 100 * sum(weight .* score);
end

function value = safeDivide(a, b)
    if b == 0
        value = NaN;
    else
        value = a / b;
    end
end

function mask = paretoMask(cost, cri, halfTime)
    n = numel(cost);
    mask = true(n, 1);
    for i = 1:n
        dominated = cost <= cost(i) & cri >= cri(i) & halfTime <= halfTime(i) & ...
            (cost < cost(i) | cri > cri(i) | halfTime < halfTime(i));
        if any(dominated)
            mask(i) = false;
        end
    end
end

function y = normalizeBenefit(x)
    x = double(x);
    xmin = min(x);
    xmax = max(x);
    if abs(xmax - xmin) < 1e-12
        y = ones(size(x));
    else
        y = (x - xmin) ./ (xmax - xmin);
    end
end

function p = findPlan(tbl, x1, x2, x3, x4)
    idx = tbl.("管网扩径_m") == x1 & tbl.("调蓄池_座") == x2 & ...
        tbl.("透水路面_m2") == x3 & tbl.("预警系统_套") == x4;
    p = tbl(find(idx, 1), :);
end

function txt = planText(plan)
    parts = strings(1, 0);
    if plan.("管网扩径_m") > 0
        parts(end + 1) = "管网扩径" + string(plan.("管网扩径_m")) + "m";
    end
    if plan.("调蓄池_座") > 0
        parts(end + 1) = "调蓄池" + string(plan.("调蓄池_座")) + "座";
    end
    if plan.("透水路面_m2") > 0
        parts(end + 1) = "透水路面" + string(plan.("透水路面_m2")) + "m2";
    end
    if plan.("预警系统_套") > 0
        parts(end + 1) = "预警系统" + string(plan.("预警系统_套")) + "套";
    end
    if isempty(parts)
        txt = "不改造";
    else
        txt = join(parts, "+");
    end
end

function cri = scenarioCri(x, factor, currentValue, idealValue, weight, secondary, ...
    idxDrain, idxLow, idxHalf, idxResp, idxStorage, idxCover, maxPipeM, ...
    maxPavementM2, fullWarningSet, pipeDrainBoost, pavementDrainBoost, ...
    pipeHalfReduce, poolHalfReduce, pavementHalfReduce, warningRespReduce)
    x1 = x(1);
    x2 = x(2);
    x3 = x(3);
    x4 = x(4);

    newValue = currentValue;
    newValue(idxDrain) = min(idealValue(idxDrain), ...
        currentValue(idxDrain) + factor(1) * pipeDrainBoost * x1 / maxPipeM + ...
        factor(3) * pavementDrainBoost * x3 / maxPavementM2);
    newValue(idxLow) = currentValue(idxLow);
    newValue(idxHalf) = max(idealValue(idxHalf), ...
        currentValue(idxHalf) * (1 - factor(1) * pipeHalfReduce * x1 / maxPipeM) * ...
        (1 - factor(2) * poolHalfReduce) ^ x2 * ...
        (1 - factor(3) * pavementHalfReduce * x3 / maxPavementM2));
    newValue(idxResp) = max(idealValue(idxResp), ...
        currentValue(idxResp) * (1 - factor(4) * warningRespReduce * x4 / fullWarningSet));
    newValue(idxStorage) = min(idealValue(idxStorage), ...
        currentValue(idxStorage) + 800 * x2 + factor(3) * 0.1 * x3);
    newValue(idxCover) = min(idealValue(idxCover), ...
        currentValue(idxCover) + (idealValue(idxCover) - currentValue(idxCover)) * ...
        min(factor(4) * x4 / fullWarningSet, 1));

    cri = calcCri(newValue, idealValue, weight, secondary);
end
