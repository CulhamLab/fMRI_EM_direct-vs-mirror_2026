function RunExperiment(participant_number, run_number)

%% Parameters

% get parameters
p = get_parameters;

% add filepaths
p.FILEPATH.ORDER = sprintf("%sPAR%02d_RUN%02d.mat", p.FOLDERS.ORDERS, participant_number, run_number);
p.FILEPATH.SAVE = sprintf("%sPAR%02d_RUN%02d_%s", p.FOLDERS.DATA, participant_number, run_number, datetime("now", "Format", "uuuu-MM-dd-HH-mm-ss"));


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
audio_file_names = [unique(d.loaded_order.audio_view); unique(d.loaded_order.audio_action); unique(d.loaded_order.audio_location); "task_complete"]';

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
arduino_LED_all_off(p)

% initialize cameras
if p.ENABLE_CAMERAS
    % Interactive picker (assign devices to Camera 1/2, choose format & input source).
    % Runs before any Psychtoolbox display calls so listdlg can grab focus.
    if isfield(p.CAMERAS, 'INTERACTIVE_SETUP') && p.CAMERAS.INTERACTIVE_SETUP
        p = CameraSetupWizard(p);
    end

    fprintf("\nInitializing cameras...\n");
    cams = InitCameras(p, participant_number, run_number);
    fprintf("Cameras ready (%d devices, %s @ %g fps).\n", ...
        numel(p.CAMERAS.DEVICE_IDS), mat2str_format(p.CAMERAS.FORMAT), p.CAMERAS.FRAME_RATE);
else
    cams = [];
    warning("ENABLE_CAMERAS IS FALSE: cameras will not be used")
end

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
      "VideoInstruction"    "string"    % empty, Start, or Stop
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
    % start video during the prior volume
    d.schedule.VideoInstruction(vol) = "Start";

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
            if v==1
                % play sound in the first volume only if multiple volumes
                d.schedule.Audio(vol) = subblock_order.audio_action(1);
                d.schedule.AudioTime(vol) = p.TIMING_IN_VOLUME.AUDIO_ACTION_START;
            end
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

    % end video during the next volume
    d.schedule.VideoInstruction(vol+1) = "Stop";
    
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
            arduino_LED_all_off
            error('Stop key was pressed.')
        end
    end
end


%% Time Zero
d.t0 = GetSecs;
t0 = d.t0; % shortcut


%% Start camera recording
if p.ENABLE_CAMERAS
    cams = StartRecording(cams);
    d.camera_start_time = GetSecs - t0;
    fprintf("Cameras recording (started %.3fs after t0).\n", d.camera_start_time);
end


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
    % PsychPortAudio('Stop', s.player);

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

    % need to start/stop video recording?
    switch d.schedule.VideoInstruction
        case "Start"
            % TODO: Karsten add start code here, must complete in <1 TR

        case "Stop"
            % TODO: Karsten add stop code here, must complete in <1 TR

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

% stop camera recording
if p.ENABLE_CAMERAS
    d.camera_stop_time = GetSecs - t0;
    cams = StopRecording(cams, p);
    fprintf("Cameras stopped (%.3fs after t0).\n", d.camera_stop_time);
    d.camera_files = cams.files;
    d.camera_frames_logged = cams.frames_logged;
    for i = 1:numel(cams.files)
        [~, name, ext] = fileparts(cams.files{i});
        fprintf("  %s%s  (%d frames)\n", name, ext, cams.frames_logged(i));
    end
    CloseCameras(cams);
end

% final save
save(p.FILEPATH.SAVE + "_COMPLETE",'p','d')

% play end audio
PsychPortAudio('FillBuffer', s.player, s.files.task_complete);
PsychPortAudio('Start', s.player);
PsychPortAudio('Stop', s.player, 1);

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

    % stop and close cameras
    if exist('cams', 'var') && ~isempty(cams)
        try cams = StopRecording(cams, p); catch, end
        try CloseCameras(cams); catch, end
    end

    % stop and close audio
    fprintf("Closing audio device...\n")
    PsychPortAudio('Stop', s.player, 1);
    PsychPortAudio('Close', s.player);

    %turn off all lights
    arduino_LED_all_off(p)

    % rethrow the error
    rethrow(err)
end
end % function RunExperiment


%% ========================================================================
%%  CAMERA HELPER FUNCTIONS
%% ========================================================================

function cams = InitCameras(p, participant_number, run_number)
% Creates two videoinput objects configured for continuous disk logging.

if numel(p.CAMERAS.DEVICE_IDS) ~= 2
    error('p.CAMERAS.DEVICE_IDS must contain exactly two device indices.');
end

if iscell(p.CAMERAS.FORMAT)
    fmt = p.CAMERAS.FORMAT;
else
    fmt = {p.CAMERAS.FORMAT, p.CAMERAS.FORMAT};
end

out_dir = fullfile(pwd, p.CAMERAS.OUTPUT_SUBDIR, ...
    sprintf('PAR%02d_RUN%02d', participant_number, run_number));
if ~exist(out_dir, 'dir')
    mkdir(out_dir);
end

info = imaqhwinfo(p.CAMERAS.ADAPTOR);
if isempty(info.DeviceIDs)
    error('No %s devices found.', p.CAMERAS.ADAPTOR);
end

timestamp = char(datetime("now", "Format", "uuuu-MM-dd-HH-mm-ss"));

cams.vid = cell(1, 2);
cams.src = cell(1, 2);
cams.files = {'', ''};
cams.frames_logged = [0, 0];
cams.active = false;

for i = 1:2
    dev_id = p.CAMERAS.DEVICE_IDS(i);
    if ~ismember(dev_id, [info.DeviceIDs{:}])
        error('Camera %d: device id %d not available on adaptor "%s".', ...
              i, dev_id, p.CAMERAS.ADAPTOR);
    end

    vid = videoinput(p.CAMERAS.ADAPTOR, dev_id, fmt{i});

    % Force RGB output (capture cards using YUV/UYVY/YUY2 otherwise
    % produce green/purple color casts in the saved video).
    try
        vid.ReturnedColorSpace = 'rgb';
    catch
        warning('Camera %d: could not set ReturnedColorSpace=rgb.', i);
    end

    src = getselectedsource(vid);

    try
        src.FrameRate = num2str(p.CAMERAS.FRAME_RATE, '%.4f');
    catch
        warning('Camera %d: could not set source FrameRate; using driver default.', i);
    end

    % Optional input-source selector (e.g. Elgato Composite vs. S-Video)
    if isfield(p.CAMERAS, 'INPUT_SOURCE') && ...
       iscell(p.CAMERAS.INPUT_SOURCE) && ...
       numel(p.CAMERAS.INPUT_SOURCE) >= i && ...
       ~isempty(p.CAMERAS.INPUT_SOURCE{i})
        try
            src.InputSource = p.CAMERAS.INPUT_SOURCE{i};
        catch
            warning('Camera %d: could not set InputSource to %s.', ...
                    i, p.CAMERAS.INPUT_SOURCE{i});
        end
    end

    vid.FramesPerTrigger = Inf;
    vid.TriggerRepeat    = 0;
    triggerconfig(vid, 'manual');
    vid.LoggingMode      = 'disk';
    vid.FramesAcquiredFcnCount = 1;

    % Assign DiskLogger for the whole-experiment recording.
    fname = sprintf('PAR%02d_RUN%02d_%s_%s', ...
        participant_number, run_number, p.CAMERAS.LABELS{i}, timestamp);
    full_path = fullfile(out_dir, fname);
    writer = VideoWriter(full_path, p.CAMERAS.VIDEO_PROFILE);
    writer.FrameRate = p.CAMERAS.FRAME_RATE;
    vid.DiskLogger = writer;
    cams.files{i} = [full_path '.' lower(writer.FileFormat)];

    cams.vid{i} = vid;
    cams.src{i} = src;
end
end

% --------------------------------------------------------------------------
function cams = StartRecording(cams)
% Starts and triggers both videoinputs back-to-back to minimise offset.
for i = 1:2
    start(cams.vid{i});
end
for i = 1:2
    trigger(cams.vid{i});
end
cams.active = true;
end

% --------------------------------------------------------------------------
function cams = StopRecording(cams, p)
% Stops both videoinputs and waits for the IAT disk logger to flush.
if ~isfield(cams, 'active') || ~cams.active
    return;
end

for i = 1:2
    if isvalid(cams.vid{i}) && strcmp(cams.vid{i}.Running, 'on')
        stop(cams.vid{i});
    end
end

deadline = GetSecs + p.CAMERAS.STOP_TIMEOUT_SEC;
for i = 1:2
    while strcmp(cams.vid{i}.Logging, 'on') && GetSecs < deadline
        pause(0.01);
    end
    if strcmp(cams.vid{i}.Logging, 'on')
        warning('Camera %d: DiskLogger did not finish within %.1f s.', ...
                i, p.CAMERAS.STOP_TIMEOUT_SEC);
    end
    cams.frames_logged(i) = cams.vid{i}.DiskLoggerFrameCount;
end

cams.active = false;
end

% --------------------------------------------------------------------------
function CloseCameras(cams)
% Stops any in-progress recording and releases both videoinput objects.
if isempty(cams) || ~isfield(cams, 'vid')
    return;
end
for i = 1:numel(cams.vid)
    v = cams.vid{i};
    if isempty(v) || ~isvalid(v)
        continue;
    end
    try
        if strcmp(v.Running, 'on')
            stop(v);
        end
    catch
    end
    try
        delete(v);
    catch
    end
end
end

% --------------------------------------------------------------------------
function p = CameraSetupWizard(p)
% Interactive picker: assign Camera 1 / Camera 2 from detected devices,
% choose a video format, and pick an input source where available.
% Mutates p.CAMERAS.DEVICE_IDS, FORMAT (as 1x2 cell), and INPUT_SOURCE.

info = imaqhwinfo(p.CAMERAS.ADAPTOR);
if isempty(info.DeviceInfo)
    error('No %s devices found.', p.CAMERAS.ADAPTOR);
end

fprintf('\nDetected %s devices:\n', p.CAMERAS.ADAPTOR);
for k = 1:numel(info.DeviceInfo)
    fprintf('  [%d] %s\n', info.DeviceInfo(k).DeviceID, info.DeviceInfo(k).DeviceName);
end

deviceLabels = arrayfun(@(d) sprintf('[ID %d] %s', d.DeviceID, d.DeviceName), ...
                       info.DeviceInfo, 'UniformOutput', false);

% Pick Camera 1
sel1 = listdlg('PromptString', {'Select device for CAMERA 1:'}, ...
               'SelectionMode', 'single', ...
               'ListString',    deviceLabels, ...
               'ListSize',      [380 200], ...
               'Name',          'Camera 1 setup');
if isempty(sel1), error('Camera 1 selection cancelled.'); end
dev1 = info.DeviceInfo(sel1);

% Pick Camera 2 (exclude Camera 1)
remainingIdx = setdiff(1:numel(info.DeviceInfo), sel1);
if isempty(remainingIdx)
    error('Only one device available; cannot assign Camera 2.');
end
sel2_rel = listdlg('PromptString', {'Select device for CAMERA 2:'}, ...
                   'SelectionMode', 'single', ...
                   'ListString',    deviceLabels(remainingIdx), ...
                   'ListSize',      [380 200], ...
                   'Name',          'Camera 2 setup');
if isempty(sel2_rel), error('Camera 2 selection cancelled.'); end
dev2 = info.DeviceInfo(remainingIdx(sel2_rel));

% Pick formats
fmt1 = pickFormat(dev1, 'Camera 1', p.CAMERAS.FORMAT);
fmt2 = pickFormat(dev2, 'Camera 2', p.CAMERAS.FORMAT);

% Pick input sources (probe by instantiating a temporary videoinput so we
% can read the InputSource property). Skip silently if not available.
src1_choice = probeInputSource(p.CAMERAS.ADAPTOR, dev1.DeviceID, fmt1, 'Camera 1');
src2_choice = probeInputSource(p.CAMERAS.ADAPTOR, dev2.DeviceID, fmt2, 'Camera 2');

% Commit choices back into p
p.CAMERAS.DEVICE_IDS  = [dev1.DeviceID, dev2.DeviceID];
p.CAMERAS.FORMAT      = {fmt1, fmt2};
p.CAMERAS.INPUT_SOURCE = {src1_choice, src2_choice};

fprintf('\nCamera 1: [ID %d] %s  (%s)\n', dev1.DeviceID, dev1.DeviceName, fmt1);
fprintf('Camera 2: [ID %d] %s  (%s)\n\n', dev2.DeviceID, dev2.DeviceName, fmt2);
end

% --------------------------------------------------------------------------
function fmt = pickFormat(dev, label, defaultFormat)
% Prompts the user to pick a video format from a device's SupportedFormats.
formats = dev.SupportedFormats;
if isempty(formats)
    error('%s: device "%s" reports no supported formats.', label, dev.DeviceName);
end

% Default selection: param value if available, then DefaultFormat, then 1
defaultIdx = 1;
candidate = '';
if iscell(defaultFormat)
    if ~isempty(defaultFormat), candidate = defaultFormat{1}; end
else
    candidate = defaultFormat;
end
hit = find(strcmp(formats, candidate), 1);
if ~isempty(hit)
    defaultIdx = hit;
elseif isfield(dev, 'DefaultFormat') && ~isempty(dev.DefaultFormat)
    hit = find(strcmp(formats, dev.DefaultFormat), 1);
    if ~isempty(hit), defaultIdx = hit; end
end

sel = listdlg('PromptString', {sprintf('Select video format for %s', label), ...
                               sprintf('(%s)', dev.DeviceName)}, ...
              'SelectionMode', 'single', ...
              'ListString',    formats, ...
              'InitialValue',  defaultIdx, ...
              'ListSize',      [380 260], ...
              'Name',          [label ' format']);
if isempty(sel)
    error('%s format selection cancelled.', label);
end
fmt = formats{sel};
end

% --------------------------------------------------------------------------
function choice = probeInputSource(adaptor, devID, fmt, label)
% Briefly instantiates a videoinput to query InputSource choices.
% Returns the selected source string, or '' if not applicable.
choice = '';
vid = [];
try
    vid = videoinput(adaptor, devID, fmt);
    src = getselectedsource(vid);
    propInfo = propinfo(src, 'InputSource');
    choices = propInfo.ConstraintValue;
    if isempty(choices) || ~iscell(choices) || numel(choices) < 2
        return;
    end
    current = ''; try current = src.InputSource; catch, end
    defaultIdx = find(strcmp(choices, current), 1);
    if isempty(defaultIdx), defaultIdx = 1; end
    sel = listdlg('PromptString', {sprintf('Select input source for %s', label)}, ...
                  'SelectionMode', 'single', ...
                  'ListString',    choices, ...
                  'InitialValue',  defaultIdx, ...
                  'ListSize',      [320 160], ...
                  'Name',          [label ' input source']);
    if isempty(sel)
        choice = current;
    else
        choice = choices{sel};
    end
catch
    choice = '';
end
if ~isempty(vid)
    try delete(vid); catch, end
end
end

% --------------------------------------------------------------------------
function s = mat2str_format(fmt)
% Pretty-print a format value (string or 1x2 cell) for the console.
if iscell(fmt)
    s = strjoin(fmt, ' | ');
else
    s = fmt;
end
end