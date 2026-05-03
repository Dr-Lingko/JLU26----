clear; clc;

projectDir = fileparts(mfilename("fullpath"));
dataFile = fullfile(projectDir, "题目", "B题附表1至6.xlsx");
outDir = fullfile(projectDir, "output");
if ~exist(outDir, "dir")
    mkdir(outDir);
end

%% Read resilience indicators from Sheet 5
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

score = zeros(size(weight));
indicatorType = strings(size(weight));
for j = 1:numel(weight)
    name = secondary(j);
    if contains(name, "低洼路段占比")
        indicatorType(j) = "逆向百分比";
        score(j) = 1 - currentValue(j) / 100;
    elseif contains(name, "半衰期") || contains(name, "时间")
        indicatorType(j) = "逆向指标";
        score(j) = idealValue(j) / currentValue(j);
    else
        indicatorType(j) = "正向指标";
        score(j) = currentValue(j) / idealValue(j);
    end
    score(j) = min(max(score(j), 0), 1);
end

weightedScore = weight .* score;
loss = weight .* (1 - score);
totalScore = 100 * sum(weightedScore);
obstacle = loss ./ sum(loss);

if totalScore >= 80
    grade = "韧性较强";
elseif totalScore >= 60
    grade = "韧性中等";
elseif totalScore >= 40
    grade = "韧性偏弱";
else
    grade = "韧性较差";
end

indicatorTable = table(primary, secondary, unitName, currentValue, idealValue, ...
    indicatorType, weight, score, 100 * weightedScore, 100 * obstacle, ...
    'VariableNames', {'一级指标', '二级指标', '单位', '现状值', '理想满分值', ...
    '指标属性', '权重', '标准化得分', '加权贡献_分', '障碍度_百分比'});
indicatorTable = sortrows(indicatorTable, "障碍度_百分比", "descend");

levelNames = unique(primary, "stable");
nLevel = numel(levelNames);
levelWeight = zeros(nLevel, 1);
levelContribution = zeros(nLevel, 1);
levelNormalizedScore = zeros(nLevel, 1);
levelObstacle = zeros(nLevel, 1);
for i = 1:nLevel
    idx = primary == levelNames(i);
    levelWeight(i) = sum(weight(idx));
    levelContribution(i) = 100 * sum(weightedScore(idx));
    levelNormalizedScore(i) = sum(weightedScore(idx)) / levelWeight(i);
    levelObstacle(i) = 100 * sum(loss(idx)) / sum(loss);
end
levelTable = table(levelNames, levelWeight, levelContribution, ...
    100 * levelNormalizedScore, levelObstacle, ...
    'VariableNames', {'一级指标', '权重合计', '加权贡献_分', ...
    '一级标准化得分_百分制', '一级障碍度_百分比'});

summaryTable = table(totalScore, grade, ...
    'VariableNames', {'综合韧性得分', '韧性等级'});

%% Road vulnerability identification based on Q1 depth / Sheet 4 depth
q1File = fullfile(outDir, "第一问_积水动态演化结果_改进.xlsx");
if exist(q1File, "file")
    depthTable = readtable(q1File, "Sheet", "15min最终积水深度", ...
        "VariableNamingRule", "preserve");
    roadId = string(depthTable{:, 1});
    depth = table2array(depthTable(:, 2:end));
    depthSource = "第一问输出的最终积水深度";
else
    raw4 = readcell(dataFile, "Sheet", "附表 4");
    roadId = string(raw4(3:10, 1));
    depth = cell2mat(raw4(3:10, 2:5));
    depthSource = "附表4逐时段最大积水深度";
end

[capacity, safety] = mapTrafficState(depth);
maxDepth = max(depth, [], 2);
avgDepth = mean(depth, 2);
avgCapacity = mean(capacity, 2);
avgSafety = mean(safety, 2);

riskIndex = 0.4 * maxDepth ./ max(maxDepth) + ...
    0.3 * (1 - avgCapacity) + 0.3 * (1 - avgSafety);
riskLevel = strings(size(roadId));
for i = 1:numel(roadId)
    if maxDepth(i) >= 30 || riskIndex(i) >= 0.75
        riskLevel(i) = "完全中断/极高风险";
    elseif maxDepth(i) >= 20 || riskIndex(i) >= 0.55
        riskLevel(i) = "高风险";
    elseif maxDepth(i) >= 10 || riskIndex(i) >= 0.35
        riskLevel(i) = "中风险";
    else
        riskLevel(i) = "低风险";
    end
end

roadRiskTable = table(roadId, maxDepth, avgDepth, avgCapacity, avgSafety, ...
    riskIndex, riskLevel, ...
    'VariableNames', {'路段编号', '最大积水深度_cm', '平均积水深度_cm', ...
    '平均通行能力', '平均安全度', '路段风险指数', '风险等级'});
roadRiskTable = sortrows(roadRiskTable, "路段风险指数", "descend");

%% Export workbook
resultFile = fullfile(outDir, "第二问_内涝韧性综合评价结果.xlsx");
if exist(resultFile, "file")
    delete(resultFile);
end
writetable(summaryTable, resultFile, "Sheet", "综合评分");
writetable(indicatorTable, resultFile, "Sheet", "指标得分与障碍度");
writetable(levelTable, resultFile, "Sheet", "一级指标评价");
writetable(roadRiskTable, resultFile, "Sheet", "薄弱路段排序");

%% Figures
figure("Color", "w");
bar(categorical(indicatorTable.("二级指标")), indicatorTable.("障碍度_百分比"));
ylabel("障碍度 (%)");
title("内涝韧性二级指标障碍度排序");
grid on;
set(gca, "XTickLabelRotation", 35);
exportgraphics(gcf, fullfile(outDir, "第二问_指标障碍度排序.png"), "Resolution", 300);

figure("Color", "w");
bar(categorical(levelTable.("一级指标")), levelTable.("一级标准化得分_百分制"));
ylabel("一级指标得分");
ylim([0, 100]);
title("内涝韧性一级指标得分");
grid on;
exportgraphics(gcf, fullfile(outDir, "第二问_一级指标得分.png"), "Resolution", 300);

figure("Color", "w");
bar(categorical(roadRiskTable.("路段编号")), roadRiskTable.("路段风险指数"));
ylabel("路段风险指数");
title("薄弱路段风险指数排序");
grid on;
exportgraphics(gcf, fullfile(outDir, "第二问_薄弱路段排序.png"), "Resolution", 300);

%% Paper-ready markdown
reportFile = fullfile(outDir, "第二问_论文表述.md");
fid = fopen(reportFile, "w", "n", "UTF-8");
fprintf(fid, "# 第二问：内涝韧性综合评价模型与结果\n\n");
fprintf(fid, "## 1 模型思路\n\n");
fprintf(fid, "附表5已经给出各二级指标权重，因此本问不再重新确定权重，而是先对不同量纲指标进行标准化，再依据给定权重计算综合韧性得分，并通过障碍度模型识别薄弱环节。薄弱路段识别则结合第一问得到的路段积水深度、通行能力和安全度进行排序。\n\n");
fprintf(fid, "正向指标采用 $s_j=x_j/x_j^*$，逆向指标采用 $s_j=x_j^*/x_j$；低洼路段占比的理想值为0，采用 $s_j=1-x_j/100$。综合韧性得分为：\n\n");
fprintf(fid, "$$R=100\\sum_j w_j s_j$$\n\n");
fprintf(fid, "指标障碍度定义为：\n\n");
fprintf(fid, "$$D_j=\\frac{w_j(1-s_j)}{\\sum_j w_j(1-s_j)}$$\n\n");
fprintf(fid, "路段风险指数定义为：\n\n");
fprintf(fid, "$$V_i=0.4\\frac{H_i^{max}}{H^{max}}+0.3(1-\\bar K_i)+0.3(1-\\bar S_i)$$\n\n");
fprintf(fid, "其中 $H_i^{max}$ 为路段最大积水深度，$\\bar K_i$ 为平均通行能力，$\\bar S_i$ 为平均安全度。\n\n");

fprintf(fid, "## 2 综合韧性评价结果\n\n");
fprintf(fid, "研究片区综合韧性得分为 **%.2f 分**，韧性等级为 **%s**。\n\n", totalScore, char(grade));
fprintf(fid, "| 一级指标 | 权重合计 | 加权贡献/分 | 一级标准化得分/分 | 一级障碍度/%% |\n");
fprintf(fid, "|---|---:|---:|---:|---:|\n");
for i = 1:height(levelTable)
    fprintf(fid, "| %s | %.2f | %.2f | %.2f | %.2f |\n", ...
        char(levelTable.("一级指标")(i)), levelTable.("权重合计")(i), ...
        levelTable.("加权贡献_分")(i), levelTable.("一级标准化得分_百分制")(i), ...
        levelTable.("一级障碍度_百分比")(i));
end

fprintf(fid, "\n## 3 指标影响程度与薄弱环节\n\n");
fprintf(fid, "障碍度越大，说明该指标对整体韧性的拖累越明显。排名前五的薄弱指标如下：\n\n");
fprintf(fid, "| 排名 | 指标 | 标准化得分 | 障碍度/%% |\n");
fprintf(fid, "|---:|---|---:|---:|\n");
for i = 1:min(5, height(indicatorTable))
    fprintf(fid, "| %d | %s | %.4f | %.2f |\n", i, ...
        char(indicatorTable.("二级指标")(i)), indicatorTable.("标准化得分")(i), ...
        indicatorTable.("障碍度_百分比")(i));
end
fprintf(fid, "\n由障碍度结果可知，积水消退半衰期、绿色调蓄容积、应急响应时间、疏散点位密度和排水能力达标率是制约片区内涝韧性的主要因素。说明该片区的核心短板不是单一排水问题，而是积水后恢复慢、调蓄能力不足和应急疏散支撑不足共同作用。\n\n");

fprintf(fid, "## 4 薄弱路段识别\n\n");
fprintf(fid, "薄弱路段识别所用积水数据来源为：%s。\n\n", depthSource);
fprintf(fid, "| 排名 | 路段 | 最大积水深度/cm | 平均通行能力 | 平均安全度 | 风险指数 | 风险等级 |\n");
fprintf(fid, "|---:|---|---:|---:|---:|---:|---|\n");
for i = 1:height(roadRiskTable)
    fprintf(fid, "| %d | %s | %.2f | %.3f | %.3f | %.3f | %s |\n", ...
        i, char(roadRiskTable.("路段编号")(i)), roadRiskTable.("最大积水深度_cm")(i), ...
        roadRiskTable.("平均通行能力")(i), roadRiskTable.("平均安全度")(i), ...
        roadRiskTable.("路段风险指数")(i), char(roadRiskTable.("风险等级")(i)));
end
fprintf(fid, "\n因此，L5、L2、L8为研究片区主要薄弱路段。其中L5最大积水深度超过30 cm，达到完全中断标准，是最优先治理对象；L2和L8最大积水深度均超过20 cm，通行能力与安全度明显下降，应作为第三问动态疏散和第四问改造优化中的重点约束路段。\n");
fclose(fid);

fprintf("Second-question results written to:\n%s\n%s\n", resultFile, reportFile);
fprintf("Total resilience score: %.2f, grade: %s\n", totalScore, char(grade));
fprintf("Top weak indicators:\n");
disp(indicatorTable(1:min(5, height(indicatorTable)), ...
    {'二级指标', '标准化得分', '障碍度_百分比'}));
fprintf("Top weak road segments:\n");
disp(roadRiskTable(1:min(5, height(roadRiskTable)), ...
    {'路段编号', '最大积水深度_cm', '路段风险指数', '风险等级'}));

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
