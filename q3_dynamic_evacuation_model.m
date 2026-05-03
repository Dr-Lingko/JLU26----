clear; clc;

projectDir = fileparts(mfilename("fullpath"));
dataFile = fullfile(projectDir, "题目", "B题附表1至6.xlsx");
q1File = fullfile(projectDir, "output", "第一问_积水动态演化结果_改进.xlsx");
outDir = fullfile(projectDir, "output");
if ~exist(outDir, "dir")
    mkdir(outDir);
end

%% Basic road data
roadRaw = readcell(dataFile, "Sheet", "附表 1");
roadId = string(roadRaw(3:10, 1));
lenM = cell2mat(roadRaw(3:10, 2));
priority = string(roadRaw(3:10, 3));
roadType = string(roadRaw(3:10, 4));
slopePermil = cell2mat(roadRaw(3:10, 5));
drainageLps = cell2mat(roadRaw(3:10, 7));
minElevationM = cell2mat(roadRaw(3:10, 8));

freeSpeedKmh = zeros(size(roadId));
freeSpeedKmh(priority == "主干路") = 40;
freeSpeedKmh(priority == "次干路") = 30;
freeSpeedKmh(priority == "支路") = 20;
freeSpeedMMin = freeSpeedKmh * 1000 / 60;
freeTimeMin = lenM ./ freeSpeedMMin;

%% Dynamic depth, capacity and safety
timeMin = [15, 30, 45, 60];
if exist(q1File, "file")
    depthTable = readtable(q1File, "Sheet", "15min最终积水深度", ...
        "VariableNamingRule", "preserve");
    capacityTable = readtable(q1File, "Sheet", "15min通行能力", ...
        "VariableNamingRule", "preserve");
    safetyTable = readtable(q1File, "Sheet", "15min安全度", ...
        "VariableNamingRule", "preserve");

    sourceRoad = string(depthTable{:, 1});
    [found, loc] = ismember(roadId, sourceRoad);
    if any(~found)
        error("Q1 result file is missing one or more road IDs.");
    end
    depth = table2array(depthTable(loc, 2:end));
    capacity = table2array(capacityTable(loc, 2:end));
    safety = table2array(safetyTable(loc, 2:end));
    depthSource = "第一问输出的最终积水深度";
else
    obsRaw = readcell(dataFile, "Sheet", "附表 4");
    sourceRoad = string(obsRaw(3:10, 1));
    [found, loc] = ismember(roadId, sourceRoad);
    if any(~found)
        error("Sheet 4 is missing one or more road IDs.");
    end
    depth = cell2mat(obsRaw(2 + loc, 2:5));
    [capacity, safety] = mapTrafficState(depth);
    depthSource = "附表4逐时段最大积水深度";
end

%% Assumed road topology
nodeId = ["N0"; "N1"; "N2"; "N3"; "N4"; "N5"; "N6"];
nodeMeaning = [
    "居民区疏散起点"
    "西侧主干路交叉口"
    "中心低洼交叉口"
    "下穿通道或低洼汇水节点"
    "东侧主干路交叉口"
    "北侧高地支路节点"
    "应急疏散点"
];

edgeRoadId = ["L1"; "L2"; "L5"; "L8"; "L3"; "L6"; "L4"; "L7"];
edgeStart = ["N0"; "N1"; "N2"; "N3"; "N0"; "N4"; "N1"; "N5"];
edgeEnd = ["N1"; "N2"; "N3"; "N6"; "N4"; "N3"; "N5"; "N6"];
edgeBasis = [
    "主干路，连接居民区与西侧主路口"
    "次干路，连接西侧主路口与中心低洼区"
    "次干路且最低洼，设为中心下穿或易涝路段"
    "次干路，连接低洼节点与疏散点方向"
    "主干路，形成东侧绕行入口"
    "主干路，连接东侧主路与低洼节点"
    "支路，连接西侧路口与北侧高地支路"
    "支路且最高、安全度最高，连接高地节点与疏散点"
];

[found, edgeRoadLoc] = ismember(edgeRoadId, roadId);
if any(~found)
    error("Topology references a road ID that does not exist in Sheet 1.");
end

topologyTable = table(edgeRoadId, edgeStart, edgeEnd, edgeBasis, ...
    lenM(edgeRoadLoc), priority(edgeRoadLoc), minElevationM(edgeRoadLoc), ...
    'VariableNames', {'路段编号', '起点节点', '终点节点', '设置依据', ...
    '长度_m', '通行优先级', '最低标高_m'});

nodeTable = table(nodeId, nodeMeaning, ...
    'VariableNames', {'节点编号', '节点含义'});

%% Dynamic Dijkstra settings
originNode = "N0";
destinationNode = "N6";
omega = 0.5;
safetyPenaltyScaleMin = 3.0;
epsSafety = 1e-6;

routeRecords = cell(numel(timeMin), 8);
edgeRecords = cell(numel(timeMin) * numel(edgeRoadId), 13);
recordRow = 0;

for k = 1:numel(timeMin)
    Kedge = capacity(edgeRoadLoc, k);
    Sedge = safety(edgeRoadLoc, k);
    Hedge = depth(edgeRoadLoc, k);

    passable = Kedge > 0;
    travelTime = inf(size(Kedge));
    travelTime(passable) = lenM(edgeRoadLoc(passable)) ./ ...
        (freeSpeedMMin(edgeRoadLoc(passable)) .* Kedge(passable));
    safetyCost = -log(max(Sedge, epsSafety));
    edgeWeight = omega * travelTime + ...
        (1 - omega) * safetyPenaltyScaleMin * safetyCost;
    edgeWeight(~passable) = inf;

    for e = 1:numel(edgeRoadId)
        travelTimeOut = travelTime(e);
        edgeWeightOut = edgeWeight(e);
        if isinf(travelTimeOut)
            travelTimeOut = NaN;
        end
        if isinf(edgeWeightOut)
            edgeWeightOut = NaN;
        end
        recordRow = recordRow + 1;
        edgeRecords(recordRow, :) = {timeMin(k), edgeRoadId(e), edgeStart(e), edgeEnd(e), ...
            lenM(edgeRoadLoc(e)), priority(edgeRoadLoc(e)), Hedge(e), Kedge(e), Sedge(e), ...
            passable(e), travelTimeOut, safetyCost(e), edgeWeightOut};
    end

    G = graph(edgeStart(passable), edgeEnd(passable), edgeWeight(passable), nodeId);
    if numnodes(G) == 0 || ~any(G.Nodes.Name == originNode) || ...
            ~any(G.Nodes.Name == destinationNode)
        bestNodePath = strings(1, 0);
        bestRoadPath = strings(1, 0);
        bestCost = inf;
        bestTime = inf;
        bestSafety = 0;
        pathStatus = "不可达";
    else
        [bestNodePathCell, bestCost] = shortestpath(G, originNode, destinationNode);
        bestNodePath = string(bestNodePathCell);
        if isempty(bestNodePath)
            bestRoadPath = strings(1, 0);
            bestTime = inf;
            bestSafety = 0;
            pathStatus = "不可达";
        else
            bestRoadPath = nodesToRoads(bestNodePath, edgeStart, edgeEnd, edgeRoadId);
            [bestTime, bestSafety] = evaluateRoadPath(bestRoadPath, roadId, lenM, ...
                freeSpeedMMin, capacity(:, k), safety(:, k));
            pathStatus = "可通行";
        end
    end

    routeRecords(k, :) = {timeMin(k), originNode, destinationNode, ...
        join(bestNodePath, "-"), join(bestRoadPath, "-"), ...
        bestTime, bestSafety, bestCost};
    if pathStatus == "不可达"
        routeRecords{k, 5} = "";
    end
end

routeTable = cell2table(routeRecords, 'VariableNames', ...
    {'时刻_min', '起点', '终点', '节点路径', '路段路径', ...
    '总疏散时间_min', '路径安全度', '综合代价'});

edgeStateTable = cell2table(edgeRecords, 'VariableNames', ...
    {'时刻_min', '路段编号', '起点节点', '终点节点', '长度_m', '通行优先级', ...
    '积水深度_cm', '通行能力系数', '安全度评分', '是否可通行', ...
    '通行时间_min', '安全惩罚', '综合边权'});

%% Candidate path comparison
candidateName = ["P1 中心直接路径"; "P2 东侧绕行路径"; "P3 北侧高地绕行路径"];
candidateRoads = {
    ["L1", "L2", "L5", "L8"]
    ["L3", "L6", "L8"]
    ["L1", "L4", "L7"]
};
candidateRows = cell(numel(timeMin) * numel(candidateName), 8);
row = 0;
for k = 1:numel(timeMin)
    for p = 1:numel(candidateName)
        row = row + 1;
        pathRoads = candidateRoads{p};
        [pathTime, pathSafety, feasible, pathCost] = evaluateCandidate(pathRoads, ...
            roadId, lenM, freeSpeedMMin, capacity(:, k), safety(:, k), ...
            omega, safetyPenaltyScaleMin, epsSafety);
        candidateRows(row, :) = {timeMin(k), candidateName(p), join(pathRoads, "-"), ...
            feasible, pathTime, pathSafety, pathCost, pathRemark(feasible, pathRoads, roadId, capacity(:, k))};
    end
end
candidateTable = cell2table(candidateRows, 'VariableNames', ...
    {'时刻_min', '候选路径', '路段组成', '是否可通行', ...
    '总疏散时间_min', '路径安全度', '综合代价', '说明'});

%% Export workbook
resultFile = fullfile(outDir, "第三问_动态疏散路径优化结果.xlsx");
if exist(resultFile, "file")
    delete(resultFile);
end
writetable(nodeTable, resultFile, "Sheet", "节点设置");
writetable(topologyTable, resultFile, "Sheet", "路网连接假设");
writetable(edgeStateTable, resultFile, "Sheet", "动态路段边权");
writetable(routeTable, resultFile, "Sheet", "动态最优路径");
writetable(candidateTable, resultFile, "Sheet", "候选路径对比");

%% Figures
baseG = graph(edgeStart, edgeEnd, ones(size(edgeRoadId)), nodeId);
figure("Color", "w");
p = plot(baseG, "Layout", "layered", "Sources", originNode, "Sinks", destinationNode, ...
    "NodeLabel", nodeId, "EdgeLabel", edgeRoadId);
title("第三问假设路网拓扑");
highlight(p, originNode, "NodeColor", [0.1 0.45 0.8], "MarkerSize", 7);
highlight(p, destinationNode, "NodeColor", [0.1 0.65 0.25], "MarkerSize", 7);
exportgraphics(gcf, fullfile(outDir, "第三问_假设路网拓扑.png"), "Resolution", 300);

figure("Color", "w");
bar(categorical(routeTable.("时刻_min")), routeTable.("总疏散时间_min"));
xlabel("时刻 (min)");
ylabel("总疏散时间 (min)");
title("动态最优路径疏散时间");
grid on;
exportgraphics(gcf, fullfile(outDir, "第三问_最优路径疏散时间.png"), "Resolution", 300);

figure("Color", "w");
plot(routeTable.("时刻_min"), routeTable.("路径安全度"), "-o", "LineWidth", 1.8);
xlabel("时刻 (min)");
ylabel("路径安全度");
ylim([0, 1]);
title("动态最优路径安全度");
grid on;
exportgraphics(gcf, fullfile(outDir, "第三问_最优路径安全度.png"), "Resolution", 300);

%% Paper-ready markdown
reportFile = fullfile(outDir, "第三问_论文表述.md");
fid = fopen(reportFile, "w", "n", "UTF-8");
fprintf(fid, "# 第三问：动态疏散路径优化模型与结果\n\n");
fprintf(fid, "## 1 路网连接关系假设\n\n");
fprintf(fid, "题目附表只给出了 L1-L8 的路段属性和逐时段积水深度，没有给出完整道路节点连接表。因此，本文在不违背附表数据的前提下，依据道路等级、最低标高和疏散逻辑构造典型路网拓扑。\n\n");
fprintf(fid, "构造原则为：L1、L3、L6 为主干路，作为主要通行骨架；L2、L5、L8 为次干路，连接主干路与中心低洼区；L5 最低标高为 198.9 m，设为中心下穿或易涝路段；L7 最低积水风险最低且标高最高，设置为通往疏散点的高地支路。\n\n");
fprintf(fid, "| 路段 | 连接节点 | 设置依据 |\n|---|---|---|\n");
for i = 1:height(topologyTable)
    fprintf(fid, "| %s | %s-%s | %s |\n", char(topologyTable.("路段编号")(i)), ...
        char(topologyTable.("起点节点")(i)), char(topologyTable.("终点节点")(i)), ...
        char(topologyTable.("设置依据")(i)));
end

fprintf(fid, "\n## 2 动态边权模型\n\n");
fprintf(fid, "根据 %s 读取每条路段在 15、30、45、60 min 的积水深度、通行能力系数和安全度评分。设路段自由流速度主干路为 40 km/h、次干路为 30 km/h、支路为 20 km/h。若第 i 条路段在时刻 t 的通行能力为 K_i(t)，则实际通行时间为：\n\n", char(depthSource));
fprintf(fid, "$$T_i(t)=\\frac{l_i}{v_i^0K_i(t)}.$$\n\n");
fprintf(fid, "当 K_i(t)=0 时，路段完全中断，算法中删除该边。为同时考虑安全性，引入安全惩罚：\n\n");
fprintf(fid, "$$R_i(t)=-\\ln(\\max\\{S_i(t),\\varepsilon\\}).$$\n\n");
fprintf(fid, "综合边权定义为：\n\n");
fprintf(fid, "$$C_i(t)=\\omega T_i(t)+(1-\\omega)\\tau R_i(t),$$\n\n");
fprintf(fid, "其中本文取 \\(\\omega=%.1f\\)，\\(\\tau=%.1f\\) min，用于将安全惩罚折算为时间代价。\n\n", omega, safetyPenaltyScaleMin);

fprintf(fid, "## 3 MATLAB 求解结果\n\n");
fprintf(fid, "以居民区节点 N0 为起点、应急疏散点 N6 为终点，逐时段运行动态 Dijkstra 算法，结果如下：\n\n");
fprintf(fid, "| 时刻/min | 最优路段路径 | 总疏散时间/min | 路径安全度 | 综合代价 |\n");
fprintf(fid, "|---:|---|---:|---:|---:|\n");
for i = 1:height(routeTable)
    fprintf(fid, "| %d | %s | %.2f | %.3f | %.3f |\n", ...
        routeTable.("时刻_min")(i), char(routeTable.("路段路径")(i)), ...
        routeTable.("总疏散时间_min")(i), routeTable.("路径安全度")(i), ...
        routeTable.("综合代价")(i));
end

fprintf(fid, "\n候选路径对比如下：\n\n");
fprintf(fid, "| 时刻/min | 候选路径 | 路段组成 | 是否可通行 | 总时间/min | 安全度 | 综合代价 |\n");
fprintf(fid, "|---:|---|---|---|---:|---:|---:|\n");
for i = 1:height(candidateTable)
    fprintf(fid, "| %d | %s | %s | %s | %s | %s | %s |\n", ...
        candidateTable.("时刻_min")(i), char(candidateTable.("候选路径")(i)), ...
        char(candidateTable.("路段组成")(i)), char(logicalText(candidateTable.("是否可通行")(i))), ...
        char(numText(candidateTable.("总疏散时间_min")(i), "%.2f")), ...
        char(numText(candidateTable.("路径安全度")(i), "%.3f")), ...
        char(numText(candidateTable.("综合代价")(i), "%.3f")));
end

fprintf(fid, "\n## 4 结果分析\n\n");
fprintf(fid, "从动态最优路径看，15、30、45、60 min 均推荐选择 L1-L4-L7。其原因是 L4、L7 位于较高标高的北侧绕行通道，尤其 L7 积水风险最低、安全度长期保持较高水平。相比之下，中心直接路径 L1-L2-L5-L8 在积水峰值阶段受到 L5 完全中断影响，45 min 时不可通行；东侧绕行路径 L3-L6-L8 虽然由主干路组成，但必须经过 L8，而 L8 在 40-55 min 附近通行能力降至 0.1，安全度明显下降。\n\n");
fprintf(fid, "因此，在极端降雨动态演化过程中，最优疏散路径不是静态距离最短路径，而是随路段积水、通行能力和安全度实时更新的动态安全路径。该结果与第二问识别出的 L5、L2、L8 为主要薄弱路段相吻合。\n");
fclose(fid);

fprintf("Third-question results written to:\n%s\n%s\n", resultFile, reportFile);
disp(routeTable);

%% Local functions
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

function roadPath = nodesToRoads(nodePath, edgeStart, edgeEnd, edgeRoadId)
    roadPath = strings(1, max(0, numel(nodePath) - 1));
    for j = 1:numel(nodePath) - 1
        a = nodePath(j);
        b = nodePath(j + 1);
        idx = (edgeStart == a & edgeEnd == b) | (edgeStart == b & edgeEnd == a);
        roadPath(j) = edgeRoadId(find(idx, 1));
    end
end

function [pathTime, pathSafety] = evaluateRoadPath(pathRoads, roadId, lenM, ...
    freeSpeedMMin, capacity, safety)
    [~, loc] = ismember(pathRoads, roadId);
    if any(loc == 0) || any(capacity(loc) <= 0)
        pathTime = inf;
        pathSafety = 0;
        return;
    end
    pathTime = sum(lenM(loc) ./ (freeSpeedMMin(loc) .* capacity(loc)));
    pathSafety = sum(lenM(loc) .* safety(loc)) / sum(lenM(loc));
end

function [pathTime, pathSafety, feasible, pathCost] = evaluateCandidate(pathRoads, ...
    roadId, lenM, freeSpeedMMin, capacity, safety, omega, safetyPenaltyScaleMin, epsSafety)
    [~, loc] = ismember(pathRoads, roadId);
    feasible = all(loc > 0) && all(capacity(loc) > 0);
    if ~feasible
        pathTime = NaN;
        pathSafety = 0;
        pathCost = NaN;
        return;
    end
    edgeTime = lenM(loc) ./ (freeSpeedMMin(loc) .* capacity(loc));
    edgeSafetyPenalty = -log(max(safety(loc), epsSafety));
    pathTime = sum(edgeTime);
    pathSafety = sum(lenM(loc) .* safety(loc)) / sum(lenM(loc));
    pathCost = sum(omega * edgeTime + (1 - omega) * safetyPenaltyScaleMin * edgeSafetyPenalty);
end

function remark = pathRemark(feasible, pathRoads, roadId, capacity)
    if feasible
        remark = "可作为候选疏散路径";
        return;
    end
    [~, loc] = ismember(pathRoads, roadId);
    valid = loc > 0;
    capOnPath = nan(size(pathRoads));
    capOnPath(valid) = capacity(loc(valid));
    blocked = pathRoads(valid & capOnPath <= 0);
    remark = "存在中断路段：" + join(blocked, "、");
end

function txt = logicalText(value)
    if value
        txt = "是";
    else
        txt = "否";
    end
end

function txt = numText(value, fmt)
    if isnan(value) || isinf(value)
        txt = "--";
    else
        txt = sprintf(fmt, value);
    end
end
