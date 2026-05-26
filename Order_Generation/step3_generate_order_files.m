
%% Output folder
fol = "..\Experiment\Orders\";
if ~exist(fol, "dir")
    mkdir(fol)
end


%% Load metablock solution

% read
meta_order = readtable("step1_solve_metablock_order.csv");

% convert char to strings
meta_order = convertvars(meta_order, @iscell, @string);


%% Define all trial position orders

position_name = ["Left" "Right"];

% use all 18 permutations of [3 left + 3 right] except LLLRRR and RRRLLL
%   Note that this does include 4 permutations with 3 of the same position 
%   in a row but they are sandwiched between the other position
position_perms = [       1     1     2     1     2     2
                         1     1     2     2     1     2
                         1     1     2     2     2     1
                         1     2     1     1     2     2
                         1     2     1     2     1     2
                         1     2     1     2     2     1
                         1     2     2     1     1     2
                         1     2     2     1     2     1
                         1     2     2     2     1     1
                         2     1     1     1     2     2
                         2     1     1     2     1     2
                         2     1     1     2     2     1
                         2     1     2     1     1     2
                         2     1     2     1     2     1
                         2     1     2     2     1     1
                         2     2     1     1     1     2
                         2     2     1     1     2     1
                         2     2     1     2     1     1];


%% Solve trial orders for all participants

% fixed RNG seed for repeatable outputs
rng(1);

% get participant numbers from meta_order
participants = unique(meta_order.Participant);

% add new columns to meta_order
action_names = ["Touch" "Precision" "WholeHand"];
for i = action_names(:)'
    meta_order.(i + "_TrialPermIndex") = nan(height(meta_order), 6);
end

% Populate orders...
for participant = participants(:)'
    for view = ["Direct" "Mirror"]
        % find meta_order
        rows = find((meta_order.Participant==participant) & (meta_order.View==view));

        % there should be exactly 3 runs
        if numel(rows) ~= 3
            error("Should be exactly 3 runs per view")
        end

        % generate trial permutations for these 3 runs
        trial_perms_order = step2_solve_trial_permutations;

        % add to meta_order
        for run = 1:3
            row = rows(run);
            for action = 1:3
                meta_order.(action_names(action) + "_TrialPermIndex")(row,:) = squeeze(trial_perms_order(run, action, :));
            end
        end
    end
end

fp = "step2_solve_trial_permutations.csv";
if exist(fp, "file")
    delete(fp)
end
writetable(meta_order, fp)


%% Generate order files

vars = ["View"      "string"
        "Metablock" "double"
        "Subblock"     "double"
        "TrialInBlock" "double"
        "Action"    "string"
        "Location"  "string"];
trials_count = 6 * 3 * 6;

for row = 1:height(meta_order)
    name = sprintf("PAR%02d_RUN%02d", meta_order.Participant(row), meta_order.Run(row));

    % initialize order table
    order = table(Size=[trials_count size(vars,1)], VariableNames=vars(:,1), VariableTypes=vars(:,2));
    order{:,:} = nan;

    % set viewing condition for run
    order.View(:) = meta_order.View(row);

    % initialize counters
    trial = 0;

    % add each metablock
    for metablock = 1:6
        for subblock = 1:3
            action_letter = meta_order.("Metablock" + metablock)(row).extract(subblock);
            action_index = find(action_names.extract(1) == action_letter);
            if length(action_index)~=1, error; end
            action = action_names(action_index);

            % get trial order
            trial_perms_ind = meta_order.(action + "_TrialPermIndex")(row, metablock);
            trial_perms = position_perms(trial_perms_ind, :);
            trial_positions = position_name(trial_perms);

            % add trials
            for trial_in_block = 1:6
                trial = trial + 1;

                order.Metablock(trial) = metablock;
                order.Subblock(trial) = subblock;
                order.TrialInBlock(trial) = trial_in_block;
                order.Action(trial) = action;
                order.Location(trial) = trial_positions(trial_in_block);
            end
        end
    end

    % save csv
    fp = fol + name + ".csv";
    if exist(fp, "file")
        delete(fp)
    end
    writetable(order, fp)

    % save mat
    fp = fol + name + ".mat";
    if exist(fp, "file")
        delete(fp)
    end
    save(fp, "order")
end


%% Done
disp Done!