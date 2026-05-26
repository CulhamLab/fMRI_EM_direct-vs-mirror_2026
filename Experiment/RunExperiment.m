function RunExperiment(participant_number, run_number)

%% Parameters

% get parameters
p = get_parameters;

% add filepaths
p.FILEPATH.ORDER = sprintf("%sPAR%02d_RUN%02d.mat", p.FOLDERS.ORDERS, participant_number, run_number);
p.FILEPATH.SAVE = sprintf("%sPAR%02d_RUN%02d_%s", p.FOLDERS.DATA, participant_number, run_number, datetime("now", Format="uuuu-MM-dd-HH-mm-ss"));


%% Prep

% error if no Psychtoolbox
if ~exist("WaitSecs")
    error("This script requires Psychtoolbox")
end

% warn if ~p.ENABLE_ARDUINO
if ~p.ENABLE_ARDUINO
    warning("ENABLE_ARDUINO IS FALSE: arduino will not be used")
end

% error if timing not divisible by TR
for T = string(fields(p.TIMING))'
    if rem(p.TIMING.(T), p.TR)
        error("p.TIMING.%s must be divisible by p.TR", T)
    end
end

% get key ID
KbName('UnifyKeyNames');
p.KEYS.TRIGGER = arrayfun(@(x) KbName(x.char), p.KEYS.TRIGGER_NAMES);
p.KEYS.STOP = arrayfun(@(x) KbName(x.char), p.KEYS.STOP_NAMES);

% precall PTB functions a few times to prevent delays
for i = 1:10
    GetSecs;
    KbCheck;
end

%create data folder if needed
if ~exist(p.FOLDERS.DATA), mkdir(p.FOLDERS.DATA); end

% load order
d.loaded_order = getfield(load(p.FILEPATH.ORDER), "order");
d.view_type = d.loaded_order.View(1);

% open audio player (one used for everything)
AssertOpenGL;
InitializePsychSound;
PsychPortAudio('Close'); % close any existing audio handles
s.player = PsychPortAudio('Open', p.SOUND.DEVICE_ID, [], 0, p.SOUND.FREQUENCY, p.SOUND.CHANNELS, [], p.SOUND.LATENCY);
PsychPortAudio('Volume', s.player, p.SOUND.VOLUME);

% determine audio for each trial
d.loaded_order.audio_view = arrayfun(@(x) "view_"+x.lower, d.loaded_order.View);
d.loaded_order.audio_action = arrayfun(@(x) "action_"+x.lower+"_500ms", d.loaded_order.Action);
d.loaded_order.audio_location = arrayfun(@(x) "location_"+x.lower+"_400ms", d.loaded_order.Location);

% unique audio files needed
audio_file_names = [unique(d.loaded_order.audio_view); unique(d.loaded_order.audio_action); unique(d.loaded_order.audio_location)]';

% load and prepare sounds
fprintf("Loading sounds:\n");
for filename = audio_file_names
    % filepath
    fp = p.FOLDERS.SOUNDS + filename + p.SOUND.FILE_TYPE;
    fprintf("  %s\n", fp);

    % exists?
    if ~exist(fp,"file")
        error("Cannot find: %s\n",fp);
    end

    % load
    [snd, freq] = audioread(fp);
    snd = snd(:,1)'; %mono

    % verify freq
    if freq ~= p.SOUND.FREQUENCY
        error("Loaded sound had unexpected encoding frequency")
    end

    % store sound
    s.files.(filename) = snd;
    
    % % %play (faster response later)
    % % PsychPortAudio('FillBuffer', s.player, s.files.(filename));
    % % PsychPortAudio('Start', s.player);
    % % PsychPortAudio('Stop', s.player, 1);
end

% initialize Arduino by turning all LEDs on
arduino_LED_all_on(p)

% precalculate key time-in-volumes
time_in_volume_can_accept_trigger =             p.TR - p.TRIGGER.TIME_BEFORE_TRIGGER_CAN_START_LOOKING_SEC;
time_in_volume_must_stop_and_look_for_trigger = p.TR - p.TRIGGER.TIME_BEFORE_TRIGGER_MUST_START_LOOKING_SEC;
time_in_volume_trigger_was_not_received =       p.TR + p.TRIGGER.TIME_AFTER_MISSED_TRIGGER_STOP_LOOKING_SEC;


%% Create volume schedule

% Overall structure
%   Baseline Initial
%   Metablock 1
%       3 Subblocks (1 per task), each is:
%           AUDIO_ACTION
%           6 trials of AUDIO_LOCATION + ACTION
%           END_OF_BLOCK (extra volume so that the last action isn't cut off at 3s)
%   Baseline Internal 1
%   Metablock 2
%   Baseline Internal 2
%   Metablock 3
%   Baseline Internal 3
%   Metablock 4
%   Baseline Internal 4
%   Metablock 5
%   Baseline Internal 5
%   Metablock 6
%   Baseline Final

% 5 volume types:
%   Baseline            no audio                    set red
%   AudioTask           immediate audio             set red
%   AudioLocation       delayed audio               set to yellow when audio starts
%   Action              no audio                    set green
%   EndofBlock          no audio                    set red after delay of p.TIMING_IN_VOLUME.AUDIO_LOCATION_START

% calculate number of volumes
d.number_metablocks = d.loaded_order.Metablock(end);
d.number_subblocks_per_metablock = d.loaded_order.Subblock(end);
d.number_trials_per_subblocks = d.loaded_order.TrialInBlock(end);

sec_per_subblock = p.TIMING.AUDIO_ACTION + ...
                   ((p.TIMING.AUDIO_LOCATION + p.TIMING.ACTION) * d.number_trials_per_subblocks) + ...
                   p.TIMING.END_OF_BLOCK;

sec_per_metablock = sec_per_subblock * d.number_subblocks_per_metablock;

d.total_duration = p.TIMING.BASELINE_INITIAL + ...
                   (p.TIMING.BASELINE_INTERNAL * (d.number_metablocks-1)) + ...
                   (sec_per_metablock * d.number_metablocks) + ...
                   p.TIMING.BASELINE_FINAL;

d.number_volumes = d.total_duration / p.TR;

% initialize table
fs = ["Volume"          "double"    % which volume is this
      "ExpectedOnset"   "double"    % relative to first trigger
      "Metablock"       "double"    % 1-6 or NaN
      "Subblock"        "double"    % 1-3 or NaN
      "Trial"           "double"    % 1-6 or NaN
      "View"            "string"    % one value per run
      "Action"          "string"    % Touch/Precision/WholeHand or empty
      "Location"        "string"    % Left/Right or empty
      "Type"            "string"    % see volume types above
      "Colour"          "string"    % red/green/blue or empty
      "ColourTime"      "double"    % 0-TR or NaN
      "Audio"           "string"    % name of audio file or empty
      "AudioTime"       "double"    % 0-TR or NaN
      ];
d.schedule = table('Size', [d.number_volumes size(fs,1)], 'VariableNames', fs(:,1), 'VariableTypes', fs(:,2));
d.schedule{:,:} = nan;
vol = 0;

% fixed view type per run
d.schedule.View(:) = d.view_type;

% volume numbers
d.schedule.Volume(:) = 1:d.number_volumes;

% volume onsets
d.schedule.ExpectedOnset(:) = 0 : p.TR: ((d.number_volumes-1) * p.TR);

% add initial baseline
for v = 1:(p.TIMING.BASELINE_INITIAL / p.TR)
    vol = vol + 1;
    d.schedule.Type(vol) = "Baseline";
    d.schedule.Colour(vol) = "Red";
    d.schedule.ColourTime(vol) = 0;
end

% add metablocks
for metablock = 1:d.number_metablocks
    % add each action subblock...
    for subblock = 1:d.number_subblocks_per_metablock
        % get loaded order
        subblock_order = d.loaded_order(d.loaded_order.Metablock==metablock & d.loaded_order.Subblock==subblock, :);
        action = subblock_order.Action(1);

        % add action audio
        for v = 1:(p.TIMING.AUDIO_ACTION / p.TR)
            vol = vol + 1;
            d.schedule.Metablock(vol) = metablock;
            d.schedule.Subblock(vol) = subblock;
            d.schedule.Action(vol) = action;
            d.schedule.Type(vol) = "AudioTask";
            d.schedule.Colour(vol) = "Red";
            d.schedule.ColourTime(vol) = 0;
            d.schedule.Audio(vol) = subblock_order.audio_action(1);
            d.schedule.AudioTime(vol) = p.TIMING_IN_VOLUME.AUDIO_ACTION_START;
        end

        % add each trial...
        for t = 1:d.number_trials_per_subblocks
            location = subblock_order.Location(t);

            % add location audio
            for v = 1:(p.TIMING.AUDIO_LOCATION / p.TR)
                vol = vol + 1;
                d.schedule.Metablock(vol) = metablock;
                d.schedule.Subblock(vol) = subblock;
                d.schedule.Trial(vol) = t;
                d.schedule.Action(vol) = action;
                d.schedule.Location(vol) = location;
                d.schedule.Type(vol) = "AudioLocation";
                d.schedule.Colour(vol) = "Yellow";
                d.schedule.ColourTime(vol) = p.TIMING_IN_VOLUME.AUDIO_LOCATION_START;
                d.schedule.Audio(vol) = subblock_order.audio_location(t);
                d.schedule.AudioTime(vol) = p.TIMING_IN_VOLUME.AUDIO_LOCATION_START;
            end

            % add action
            for v = 1:(p.TIMING.ACTION / p.TR)
                vol = vol + 1;
                d.schedule.Metablock(vol) = metablock;
                d.schedule.Subblock(vol) = subblock;
                d.schedule.Trial(vol) = t;
                d.schedule.Action(vol) = action;
                d.schedule.Location(vol) = location;
                d.schedule.Type(vol) = "Action";
                d.schedule.Colour(vol) = "Green";
                d.schedule.ColourTime(vol) = 0;
            end
        end

        % add end of subblock volume
        for v = 1:(p.TIMING.END_OF_BLOCK / p.TR)
            vol = vol + 1;
            d.schedule.Metablock(vol) = metablock;
            d.schedule.Subblock(vol) = subblock;
            % d.schedule.Trial(vol) = t;
            d.schedule.Action(vol) = action;
            d.schedule.Location(vol) = location;
            d.schedule.Type(vol) = "EndofBlock";
            d.schedule.Colour(vol) = "Red";
            d.schedule.ColourTime(vol) = p.TIMING_IN_VOLUME.AUDIO_LOCATION_START;
        end
    end
    
    % add internal baseline
    if metablock < d.number_metablocks
        for v = 1:(p.TIMING.BASELINE_INTERNAL / p.TR)
            vol = vol + 1;
            d.schedule.Type(vol) = "Baseline";
            d.schedule.Colour(vol) = "Red";
            d.schedule.ColourTime(vol) = 0;
        end
    end
end

% add final baseline
for v = 1:(p.TIMING.BASELINE_FINAL / p.TR)
    vol = vol + 1;
    d.schedule.Type(vol) = "Baseline";
    d.schedule.Colour(vol) = "Red";
    d.schedule.ColourTime(vol) = 0;
end

% check number of volumes
if vol ~= d.number_volumes
    error("Logic error in per-volume schedule creation, an unexpected number of volumes were defined")
end


%% Initialize volume data
d.volume_data(1:d.number_volumes) = struct( 'time_startActual', nan, ...
                                            'time_start', nan, ...
                                            'time_endActual', nan, ...
                                            'volDuration', nan, ...
                                            'volDurationActual', nan, ...
                                            'recievedTrigger', false, ...
                                            'schedule', [], ...
                                            'audio_start_time', nan, ...
                                            'LED_colour_time', nan ...
                                            );


%% Display and play view type audio
fprintf("\n\nView Condition: %s\n\n\n", d.view_type);
PsychPortAudio('FillBuffer', s.player, s.files.(d.loaded_order.audio_view(1)));
PsychPortAudio('Start', s.player);
PsychPortAudio('Stop', s.player, 1);


%% Turn off all lights except for fixation
arduino_LED_all_off(p)
arduino_LED_fixation_on(p)


%% Wait for first trigger
fprintf('\n\n\nWaiting for first trigger (%d volumes)...\n\n\n',d.number_volumes)
while 1
    [keyIsDown, ~, keyCode] = KbCheck(-1); %get key(s)
    if keyIsDown
        if any(keyCode(p.KEYS.TRIGGER))
            break
        elseif any(keyCode(p.KEYS.STOP))
            error('Stop key was pressed.')
        end
    end
end


%% Time Zero
d.t0 = GetSecs;
t0 = d.t0; % shortcut


%% Run per-volume events
try
for vol = 1:d.number_volumes
    % volume start time actual
    if vol==1
        d.volume_data(vol).time_startActual = 0;
    else
        d.volume_data(vol).time_startActual = GetSecs-t0;
    end

    % volume start time
    if vol==1 || d.volume_data(vol-1).recievedTrigger %is first vol OR prior vol recieved trigger
        d.volume_data(vol).time_start = d.volume_data(vol).time_startActual; %use actual time
    else %missed a trigger
        d.volume_data(vol).time_start = d.volume_data(vol-1).time_start + p.TR; %use expected trigger time
    end

    % start message
    fprintf("\nStarting volume %d/%d at %.3fsec (actual %.3fsec):\n",vol,d.number_volumes,d.volume_data(vol).time_start,d.volume_data(vol).time_startActual);

    % store volume events
    d.volume_data(vol).schedule = d.schedule(vol,:);
    disp(d.volume_data(vol).schedule)

    % always stop audio at start of volume to prevent potential glitchy noise
    PsychPortAudio('Stop', s.player);

    % has audio?
    if ismissing(d.schedule.Audio(vol))
        audio_complete = true;
    else
        audio_complete = false;
        audio_to_play = d.volume_data(vol).schedule.Audio;
        audio_time = d.schedule.AudioTime(vol);
    end

    % has LED colour?
    if ismissing(d.schedule.Colour(vol))
        colour_complete = true;
    else
        colour_complete = false;
        colour_to_set = d.schedule.Colour(vol);
        colour_time = d.schedule.ColourTime(vol);
    end

    % play out events...
    while 1
        % time
        t = GetSecs - t0;                          % time relative to first volume
        t_vol = t - d.volume_data(vol).time_start; % time in volume

        % start audio?
        if ~audio_complete & (t_vol >= audio_time)
            PsychPortAudio('FillBuffer', s.player, s.files.(audio_to_play));
            PsychPortAudio('Start', s.player);
            d.volume_data(vol).audio_start_time = t_vol;
            audio_complete = true;
        end

        % time
        t = GetSecs - t0;                          % time relative to first volume
        t_vol = t - d.volume_data(vol).time_start; % time in volume

        % change LED colour?
        if ~colour_complete & (t_vol >= colour_time)
            arduino_LED_set_colour(colour_to_set, p)
            d.volume_data(vol).LED_colour_time = t_vol;
            colour_complete = true;
        end

        % trigger or key press?
        [keyIsDown, ~, keyCode] = KbCheck(-1);
        if keyIsDown
            if any(keyCode(p.KEYS.TRIGGER)) && (t_vol >= time_in_volume_can_accept_trigger)
                d.volume_data(vol).recievedTrigger = true;
                fprintf("~~~~~~~~~~~~~~~~~TRIGGER RECIEVED~~~~~~~~~~~~~~~~~\n")
                break
            elseif any(keyCode(p.KEYS.STOP))
                error('Stop key was pressed.')
            end
        end

        % time
        t = GetSecs - t0;                          % time relative to first volume
        t_vol = t - d.volume_data(vol).time_start; % time in volume

        % stop if it's very late in the volume, need to exclusively look for the trigger
        if t_vol >= time_in_volume_must_stop_and_look_for_trigger
            break; 
        end
    end

    % look for trigger if not yet received
    if ~d.volume_data(vol).recievedTrigger
        while 1
            %time
            t = GetSecs - t0;
            t_vol = t - d.volume_data(vol).time_start;

            % trigger or key press?
            [keyIsDown, ~, keyCode] = KbCheck(-1);
            if keyIsDown
                if any(keyCode(p.KEYS.TRIGGER))
                    d.volume_data(vol).recievedTrigger = true;
                    fprintf("~~~~~~~~~~~~~~~~~TRIGGER RECIEVED~~~~~~~~~~~~~~~~~\n")
                    break
                elseif any(keyCode(p.KEYS.STOP))
                    error('Stop key was pressed.')
                end
            end

            % stop if we go over time
            if t_vol >= time_in_volume_trigger_was_not_received
                warning("No trigger was recieved. Continuing with expected timing...")
                break; 
            end
        end
    end

    %end of volume
    d.volume_data(vol).time_endActual = GetSecs-t0;
    d.volume_data(vol).volDuration = d.volume_data(vol).time_endActual - d.volume_data(vol).time_start;
    d.volume_data(vol).volDurationActual = d.volume_data(vol).time_endActual - d.volume_data(vol).time_startActual;
    fprintf("-duration: %.3f seconds\n",d.volume_data(vol).volDuration)

end % end of volume loop

%% Done

%final save
save(p.FILEPATH.SAVE + "_COMPLETE",'p','d')

% stop and close audio
fprintf("Closing audio device...\n")
PsychPortAudio('Stop', s.player, 1);
PsychPortAudio('Close', s.player);

%turn off all lights
arduino_LED_all_off(p)

disp Done!


%% Catch
catch err
    % save
    save(p.FILEPATH.SAVE + "_ERROR")

    % stop and close audio
    fprintf("Closing audio device...\n")
    PsychPortAudio('Stop', s.player, 1);
    PsychPortAudio('Close', s.player);
    
    %turn off all lights
    arduino_LED_all_off(p)

    % rethrow the error
    rethrow(err)
end