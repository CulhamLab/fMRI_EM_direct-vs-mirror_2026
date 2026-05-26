%% Names

actions = ["Touch" "Precision" "Whole"];


%% Define the 6 metablocks

metablocks = table;
metablocks.ActionOrder = [ 1 2 3
                           1 3 2
                           2 1 3
                           2 3 1
                           3 1 2
                           3 2 1 ];
metablocks.ActionOrderNames = arrayfun(@(i) actions(i), metablocks.ActionOrder);
metablocks.Name = string(arrayfun(@(i) actions(i).extract(1).char, metablocks.ActionOrder));


metablock_count = height(metablocks);


%% Initialize orders

par_count = 24;
run_count = 6;

vars = ["Participant"     "double"
        "Run"             "double"
        "View"            "string"];
for i = 1:metablock_count
    vars(end+1,:) = ["Metablock"+i , "string"];
end
orders = table(Size=[(par_count * run_count) size(vars,1)], VariableNames=vars(:,1), VariableTypes=vars(:,2));
orders{:,:} = nan;


%% Fixed RNG seed for repeatable outputs

rng(1);


%% For each participant, predefine the first metablock of the first run
% -Within each 6 sequential participants, every metablock occurs first exactly once
% -However, the actual order across each 6 is randomized to keep this separate from the alternating initial viewing condition 
% -Additionally, each combination of first metablock and initial viewing condtion occurs exactly twice across the 24 participants

% define 2 repeats of each combination
all_combinations = [];
for first_view = 1:2
    for rep = 1:2
        all_combinations = [all_combinations; (1:metablock_count)' repmat(first_view, [metablock_count 1])];
    end
end
all_combinations = array2table(all_combinations, VariableNames=["FirstMetablock" "FirstView"]);

% populate in order
predefine_first_metablock_and_viewing = all_combinations;
predefine_first_metablock_and_viewing{:,:} = nan;
predefine_first_metablock_and_viewing.Group = ceil((1:height(all_combinations)) / metablock_count)';
for i = 1:height(all_combinations)
    % alternate viewing
    view = mod(i-1, 2) + 1;
    valid = all_combinations.FirstView == view;

    % which metablocks have been used in this group already?
    used = predefine_first_metablock_and_viewing.FirstMetablock(predefine_first_metablock_and_viewing.Group == predefine_first_metablock_and_viewing.Group(i));

    % remove used options
    valid = valid & arrayfun(@(x) ~any(x == used), all_combinations.FirstMetablock);
    
    % should always be a valid option
    if ~any(valid)
        error
    end

    % random selection of any valid option
    options = find(valid);
    select = options(randperm(length(options), 1));
    
    % apply
    predefine_first_metablock_and_viewing.FirstMetablock(i) = all_combinations.FirstMetablock(select);
    predefine_first_metablock_and_viewing.FirstView(i) =      all_combinations.FirstView(select);
    all_combinations(select,:) = [];
end


%% Populate orders

row = 0;
for participant = 1:par_count
    %% Run view order
    % -Within participant, always 3 runs of A, then 3 runs of B
    % -Across participants, alternates between starting with Direct vs Mirror (predefined above)
    switch predefine_first_metablock_and_viewing.FirstView(participant)
        case 1
            run_view = [repmat("Direct", [1 3]) repmat("Mirror", [1 3])];
        case 2
            run_view = [repmat("Mirror", [1 3]) repmat("Direct", [1 3])];
        otherwise
            error
    end
    

    %% First metablock of each run
    % -Across each 6 sequential participants, each metablock occurs first once (see above) 
    % -Within participant, one run begins with each metablock
    % -Within participant, both viewing conditions begin with each action once

    % first metablock of the first run is predefined above
    very_first_metablock = predefine_first_metablock_and_viewing.FirstMetablock(participant);

    % randomly select the first metablocks of the remaining runs such that
    % each half begins with all 3 actions
    all_combinations = setdiff(1:metablock_count, very_first_metablock);
    while 1
        % randomize first metablocks in runs 2-5
        run_first_metablock = [very_first_metablock all_combinations(randperm(length(all_combinations)))]';

        % check if runs 1-3 would contain all 3 actions
        if ~allunique( metablocks.ActionOrder(run_first_metablock(1:3),1) )
            % no = try again
            continue
        else
            % yes = stop
            break
        end
    end

    
    %% Metablocks in positions 2-5 in each run are randomly assigned such that:
    %   -Each run contains 1 of each metablock
    %   -Each position contains 1 of each metablock

    solved = false;
    while ~solved

        % initialize
        solved = true;
        run_metablocks = nan(run_count, metablock_count);
    
        % set first position
        run_metablocks(:,1) = run_first_metablock;

        % each metablock can only follow each other metablock once
        order_used = zeros(metablock_count, metablock_count);
    
        % populate
        for run = 1:run_count
            for position = 2:metablock_count
                % which metablocks already exist in this run/position?
                used = unique([run_metablocks(run,:) run_metablocks(:,position)']);
    
                % which metablocks could follow the prior one?
                could_follow = find(~order_used(:, run_metablocks(run,position-1)));

                % options
                options = setdiff(could_follow, used);
    
                % if there are no options, restart and try again
                if isempty(options)
                    solved = false;
                    break;
                end

                % randomly pick any option
                select = options(randperm(length(options), 1));
                run_metablocks(run,position) = select;
                order_used(select, run_metablocks(run,position-1)) = order_used(select, run_metablocks(run,position-1)) + 1;

            end
            if ~solved
                break
            end
        end

        if any(order_used(:) > 1)
            error
        end
    end


    %% Add solution to order table
    
    for run = 1:run_count
        row = row + 1;
        orders.Participant(row) = participant;
        orders.Run(row) = run;
        orders.View(row) = run_view(run);
        for i = 1:metablock_count
            orders.("Metablock"+i)(row) = metablocks.Name(run_metablocks(run,i));
        end
    end



end

disp(orders)

fp = mfilename + ".csv";
if exist(fp, "file")
    delete(fp)
end
writetable(orders, fp)