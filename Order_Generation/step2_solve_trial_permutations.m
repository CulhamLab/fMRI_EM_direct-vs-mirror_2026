function [trial_perms_order] = step2_solve_trial_permutations

% Rules
%   1. In each run, use all 18 permutations exactly once
%   2. For each view (3 runs), each action will use each permutations exactly once

% Uses a 3x3x6 matrix
%   3 runs
%   3 action
%   6 repeats

% Loop until a solution is found...
while 1

    % Default to success
    success = true;
    
    % Initialize
    trial_perms_order = nan(3, 3, 6);
    
    % Populate
    for run = 1:3
        for action = 1:3
            for rep = 1:6
                % start with all 18 options available
                options = 1:18;
    
                % remove any that have been used in this run
                used_run = trial_perms_order(run, :, :);
                options = setdiff(options, used_run);
    
                % remove any that have been used for this action
                used_action = trial_perms_order(:, action, :);
                options = setdiff(options, used_action);
    
                % Are there any options?
                if isempty(options)
                    success = false;
                    break
                end
    
                % Randomly select one of the available options
                selected = options(randi(numel(options)));
                trial_perms_order(run, action, rep) = selected;
    
            end
            if ~success, break; end
        end
        if ~success, break; end
    end
    
    % stop looping if solved
    if success
        break
    end
end

% Rule 1: verify that each run contains all 18 permutations
for run = 1:3
    perms_used = trial_perms_order(run, :, :);

    if any(isnan(perms_used(:)))
        error('Run %d contains a NaN permutation!', run);
    elseif numel( unique(perms_used) ) ~= 18
        error('Run %d does not contain all 18 permutations!', run);
    end
end

% Rule 2: verify that each action uses all 18 permutations across runs/repeats
for action = 1:3
    perms_used = trial_perms_order(:, action, :);

    if any(isnan(perms_used(:)))
        error('Action %d contains a NaN permutation!', action);
    elseif numel( unique(perms_used) ) ~= 18
        error('Action %d does not contain all 18 permutations!', action);
    end
end