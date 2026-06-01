function [p] = get_parameters(p) 

%% Debug / Testing
p.ENABLE_ARDUINO = true;


%% Timing

% Volume Duration
%   WARNING: Several changes will be needed if this value is adjusted
p.TR = 1; % in seconds

% Timing (in seconds)
% MUST BE DIVISIBLE BY TR
p.TIMING.BASELINE_INITIAL = 16;
p.TIMING.AUDIO_ACTION =      1; % audio plays at the start of the volume
p.TIMING.AUDIO_LOCATION =    1; % note that this volume may include some of the prior action, next trial's audio plays at the END of the volume
p.TIMING.ACTION =            3; % task duration is AUDIO_LOCATION + ACTION
p.TIMING.END_OF_BLOCK =      1; % trials are intended to be 0.5s audio --> 3.5s action, need an extra volume at the end of the block for the last 0.5s of the last trial
p.TIMING.BASELINE_INTERNAL =16; % between metablocks
p.TIMING.BASELINE_FINAL =   16;

% Timing for in-volume events
%   Note that audio is stopped at the beginning of every volume to prevent
%   potential noise so audio should be triggered at the start of a volume
%   instead of the end of the prior volume
p.TIMING_IN_VOLUME.AUDIO_ACTION_START     = 0.0;    % start at beginning of volume  
p.TIMING_IN_VOLUME.AUDIO_LOCATION_START   = 0.6;    % location cues are 0.4s long so start them at 0.6s

% Trigger timing
p.TRIGGER.TIME_BEFORE_TRIGGER_MUST_START_LOOKING_SEC = 0.010; % MUST be less than TR
p.TRIGGER.TIME_BEFORE_TRIGGER_CAN_START_LOOKING_SEC =  0.500;
p.TRIGGER.TIME_AFTER_MISSED_TRIGGER_STOP_LOOKING_SEC = 0.005;


%% Audio

p.SOUND.VOLUME = 1;         % 1.0 is 100%, can increase or decrease
p.SOUND.LATENCY = .08;      % lower = better timing, too low = loss of audio quality or crash
p.SOUND.CHANNELS = 1;       % 1 = play in mono
p.SOUND.DEVICE_ID = [];     % shouldn't need to specify
p.SOUND.FREQUENCY = 44100;  % must match the file properties
p.SOUND.FILE_TYPE = ".wav"; % .wav works reliably


%% Arduino

% Pins
p.ARDUINO.FIXATION.PIN =     10; % could use 2 for the larger LED 
% p.ARDUINO.ILLUM.PIN =       4; %not currently used
p.ARDUINO.RED.PIN =           6;
p.ARDUINO.GREEN.PIN =         8;

% LED brightness (1-255)
p.ARDUINO.FIXATION.BRIGHTNESS =     255;
% p.ARDUINO.ILLUM.BRIGHTNESS =      255;
p.ARDUINO.RED.BRIGHTNESS =          255;
p.ARDUINO.GREEN.BRIGHTNESS =        255;


%% Cameras

p.ENABLE_CAMERAS = true;
p.CAMERAS.INTERACTIVE_SETUP = true;            % show device/format/input-source picker at script start
p.CAMERAS.ADAPTOR        = 'winvideo';
p.CAMERAS.DEVICE_IDS     = [1, 2];
p.CAMERAS.LABELS         = {'cam0', 'cam1'};
p.CAMERAS.FORMAT         = 'UYVY_720x480';                       % Elgato Video Capture (NTSC)
p.CAMERAS.RESOLUTION     = [720, 480];
p.CAMERAS.FRAME_RATE     = 29.97;                                % NTSC
p.CAMERAS.INPUT_SOURCE   = {'Composite-Video', 'Composite-Video'};% Elgato composite input on both cards
p.CAMERAS.VIDEO_PROFILE  = 'MPEG-4';
p.CAMERAS.OUTPUT_SUBDIR  = 'Videos';          % under working directory
p.CAMERAS.STOP_TIMEOUT_SEC = 5.0;             % max wait for DiskLogger flush


%% Folders

p.FOLDERS.ORDERS = "." + filesep + "Orders" + filesep;
p.FOLDERS.DATA = "." + filesep + "Data" + filesep;
p.FOLDERS.SOUNDS = "." + filesep + "Audio" + filesep;
p.FOLDERS.VIDEOS = "." + filesep + "Videos" + filesep;


%% Buttons

p.KEYS.TRIGGER_NAMES = ["5%" "t"];      % support both number and letter input modes
p.KEYS.STOP_NAMES = ["ESCAPE"];

