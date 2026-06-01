%% Clear preview session
clear
clear all
clc

%% Dual Camera Simultaneous Recording
% Requires: Image Acquisition Toolbox

%% --- CONFIGURATION ---
outputDir   = 'C:\Videos';          % Change to your desired output folder
duration    = 20;                   % Recording duration in seconds
frameRate   = 30;                   % Frames per second
videoFormat = 'MPEG-4';            % 'MPEG-4', 'Motion JPEG AVI', etc.
adaptorName = 'winvideo';          % 'winvideo' (Windows), 'macvideo' (Mac), 'linuxvideo' (Linux)

%% --- DISCOVER AVAILABLE CAMERAS ---
info = imaqhwinfo(adaptorName);
if isempty(info.DeviceInfo)
    error('No %s devices found.', adaptorName);
end

disp('Available devices:');
for k = 1:numel(info.DeviceInfo)
    fprintf('  [%d] %s\n', info.DeviceInfo(k).DeviceID, info.DeviceInfo(k).DeviceName);
end

%% --- INTERACTIVE CAMERA ASSIGNMENT ---
% Build a human-readable label per device for the picker
deviceLabels = arrayfun(@(d) sprintf('[ID %d] %s', d.DeviceID, d.DeviceName), ...
                       info.DeviceInfo, 'UniformOutput', false);

% Assign Camera 1
sel1 = listdlg('PromptString', {'Select device for CAMERA 1:'}, ...
               'SelectionMode', 'single', ...
               'ListString',    deviceLabels, ...
               'ListSize',      [380 200], ...
               'Name',          'Camera 1 setup');
if isempty(sel1), error('Camera 1 selection cancelled.'); end
dev1 = info.DeviceInfo(sel1);

% Assign Camera 2 (exclude device picked for Camera 1)
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

% Pick a video format per camera from that device's SupportedFormats
fmt1 = pickFormat(dev1, 'Camera 1');
fmt2 = pickFormat(dev2, 'Camera 2');

fprintf('\nCamera 1: [ID %d] %s  (%s)\n', dev1.DeviceID, dev1.DeviceName, fmt1);
fprintf('Camera 2: [ID %d] %s  (%s)\n\n', dev2.DeviceID, dev2.DeviceName, fmt2);

%% --- CREATE VIDEO INPUT OBJECTS ---
vid1 = videoinput(adaptorName, dev1.DeviceID, fmt1);
vid2 = videoinput(adaptorName, dev2.DeviceID, fmt2);

% Force RGB output regardless of the camera's native pixel format
% (YUV/UYVY/YUY2 from capture cards like the Elgato otherwise render
% with green/purple color casts).
try vid1.ReturnedColorSpace = 'rgb'; catch, warning('Camera 1: could not set ReturnedColorSpace=rgb.'); end
try vid2.ReturnedColorSpace = 'rgb'; catch, warning('Camera 2: could not set ReturnedColorSpace=rgb.'); end

% Configure source properties
src1 = getselectedsource(vid1);
src2 = getselectedsource(vid2);

% Optional input-source selector (e.g. Elgato Composite vs. S-Video)
pickInputSource(src1, 'Camera 1');
pickInputSource(src2, 'Camera 2');

% Set frame rate (if supported by your camera/driver)
try src1.FrameRate = num2str(frameRate, '%.4f'); catch, warning('Camera 1: could not set FrameRate.'); end
try src2.FrameRate = num2str(frameRate, '%.4f'); catch, warning('Camera 2: could not set FrameRate.'); end

%% --- CONFIGURE ACQUISITION ---
framesPerTrigger = Inf;            % Capture continuously until stopped

vid1.FramesPerTrigger = framesPerTrigger;
vid2.FramesPerTrigger = framesPerTrigger;

vid1.TriggerRepeat   = 0;
vid2.TriggerRepeat   = 0;

% Use manual trigger so both cameras start at the same time
triggerconfig(vid1, 'manual');
triggerconfig(vid2, 'manual');

%% --- START ACQUISITION (also used for preview) ---
start(vid1);
start(vid2);

trigger(vid1);
trigger(vid2);

%% --- LIVE PREVIEW ---
fig = figure('Name', 'Camera Preview — Close or press Start Recording to begin', ...
             'NumberTitle', 'off', 'MenuBar', 'none', 'ToolBar', 'none');

ax1 = subplot(1, 2, 1, 'Parent', fig);
title(ax1, 'Camera 1');
ax2 = subplot(1, 2, 2, 'Parent', fig);
title(ax2, 'Camera 2');

uicontrol('Style', 'pushbutton', 'String', 'Start Recording', ...
          'Units', 'normalized', 'Position', [0.35 0.02 0.3 0.07], ...
          'FontSize', 12, 'BackgroundColor', [0.2 0.7 0.2], 'ForegroundColor', 'white', ...
          'Callback', @(~,~) set(fig, 'UserData', 'record'));

disp('Preview running. Adjust cameras, then click "Start Recording".');

% Preview loop — runs until user clicks the button or closes the figure
im1 = []; im2 = [];
while ishandle(fig) && ~strcmp(get(fig, 'UserData'), 'record')
    if vid1.FramesAvailable > 0
        f1 = getdata(vid1, 1, 'uint8');
        f1 = squeeze(f1(:,:,:,1));
        if isempty(im1)
            im1 = imshow(f1, 'Parent', ax1);
            title(ax1, 'Camera 1');
        else
            set(im1, 'CData', f1);
        end
    end
    if vid2.FramesAvailable > 0
        f2 = getdata(vid2, 1, 'uint8');
        f2 = squeeze(f2(:,:,:,1));
        if isempty(im2)
            im2 = imshow(f2, 'Parent', ax2);
            title(ax2, 'Camera 2');
        else
            set(im2, 'CData', f2);
        end
    end
    drawnow limitrate;
end

if ~ishandle(fig)
    disp('Preview closed. Aborting.');
    stop(vid1); stop(vid2);
    delete(vid1); delete(vid2);
    return;
end

disp('Starting recording...');

% Update window title and add a red REC indicator that stays on during recording
set(fig, 'Name', 'Camera Preview — RECORDING');
recIndicator = annotation(fig, 'textbox', [0.42 0.92 0.16 0.06], ...
    'String', [char(9679) ' REC'], ...
    'Color', [1 1 1], 'BackgroundColor', [0.85 0.1 0.1], ...
    'FontSize', 14, 'FontWeight', 'bold', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
    'EdgeColor', 'none');

% Tint axis titles red to reinforce the recording state
set(get(ax1, 'Title'), 'String', 'Camera 1  [REC]', 'Color', [0.85 0.1 0.1]);
set(get(ax2, 'Title'), 'String', 'Camera 2  [REC]', 'Color', [0.85 0.1 0.1]);

%% --- SET UP VIDEO WRITERS ---
if ~exist(outputDir, 'dir')
    mkdir(outputDir);
end

timestamp = datestr(now, 'yyyymmdd_HHMMSS');

vWriter1 = VideoWriter(fullfile(outputDir, ['cam0_' timestamp]), videoFormat);
vWriter2 = VideoWriter(fullfile(outputDir, ['cam1_' timestamp]), videoFormat);

vWriter1.FrameRate = frameRate;
vWriter2.FrameRate = frameRate;

open(vWriter1);
open(vWriter2);

% Drop every frame that arrived during the preview phase so both
% cameras start the recording from an empty buffer
flushdata(vid1);
flushdata(vid2);

disp(['Recording started. Duration: ' num2str(duration) ' seconds...']);
startTime = tic;

%% --- CAPTURE LOOP ---
% Frames are paired by capture timestamp. If one camera's head frame is
% more than half a frame period ahead of the other's, we drop the older
% frame on the lagging side until the pair lines up — this prevents
% drift from accumulating across the session.
frameCount = 0;
lastBlink = tic;
blinkOn = true;
framePeriod = 1 / frameRate;
syncTolerance = framePeriod / 2;
maxOffset = 0;

while toc(startTime) < duration
    % Abort cleanly if the user closes the preview window
    if ~ishandle(fig)
        disp('Preview window closed during recording. Stopping.');
        break;
    end

    % Wait until at least one frame is available from both cameras
    if vid1.FramesAvailable > 0 && vid2.FramesAvailable > 0

        % Retrieve one frame from each camera along with its capture
        % timestamp (seconds since the trigger)
        [frame1, t1] = getdata(vid1, 1, 'uint8');
        [frame2, t2] = getdata(vid2, 1, 'uint8');

        % Align by timestamp: drop the older head frame on whichever
        % camera is behind until both timestamps are within tolerance
        while abs(t1 - t2) > syncTolerance
            if t1 < t2 && vid1.FramesAvailable > 0
                [frame1, t1] = getdata(vid1, 1, 'uint8');
            elseif t2 < t1 && vid2.FramesAvailable > 0
                [frame2, t2] = getdata(vid2, 1, 'uint8');
            else
                break;  % can't catch up this iteration; write what we have
            end
        end

        offset = abs(t1 - t2);
        if offset > maxOffset
            maxOffset = offset;
        end

        % getdata returns [Height x Width x Channels x N]
        % squeeze to [H x W x C] for VideoWriter
        frame1 = squeeze(frame1(:,:,:,1));
        frame2 = squeeze(frame2(:,:,:,1));

        writeVideo(vWriter1, frame1);
        writeVideo(vWriter2, frame2);

        % Mirror the frames into the preview so the user can see what's
        % being recorded in real time
        set(im1, 'CData', frame1);
        set(im2, 'CData', frame2);

        frameCount = frameCount + 1;
    end

    % Blink the REC indicator roughly twice a second
    if toc(lastBlink) > 0.5
        blinkOn = ~blinkOn;
        if blinkOn
            set(recIndicator, 'BackgroundColor', [0.85 0.1 0.1], 'Color', [1 1 1]);
        else
            set(recIndicator, 'BackgroundColor', [0.3 0.0 0.0], 'Color', [0.7 0.7 0.7]);
        end
        lastBlink = tic;
    end

    drawnow limitrate;
end

%% --- STOP AND CLEAN UP ---
stop(vid1);
stop(vid2);

close(vWriter1);
close(vWriter2);

delete(vid1);
delete(vid2);

clear vid1 vid2 vWriter1 vWriter2;

if ishandle(fig)
    close(fig);
end

disp('Recording complete.');
disp(['Frames captured: ' num2str(frameCount)]);
disp(['Max inter-camera offset: ' num2str(maxOffset * 1000, '%.1f') ' ms']);
disp(['Files saved to: ' outputDir]);


%% ========================================================================
%%  LOCAL HELPER FUNCTIONS
%% ========================================================================

function fmt = pickFormat(dev, label)
% Prompts the user to pick a video format from a device's SupportedFormats.
% If a default format is reported, it is pre-selected in the list.
formats = dev.SupportedFormats;
if isempty(formats)
    error('%s: device "%s" reports no supported formats.', label, dev.DeviceName);
end

% Try to default to the device's reported default format
defaultIdx = 1;
if isfield(dev, 'DefaultFormat') && ~isempty(dev.DefaultFormat)
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
function pickInputSource(src, label)
% If the source object exposes an InputSource property with multiple
% choices (e.g. Elgato Video Capture: Composite-Video / S-Video),
% prompt the user to pick one. Single-choice or absent => no-op.
try
    propInfo = propinfo(src, 'InputSource');
catch
    return;  % no InputSource property
end

choices = propInfo.ConstraintValue;
if isempty(choices) || ~iscell(choices) || numel(choices) < 2
    return;  % nothing to pick
end

current = '';
try current = src.InputSource; catch, end
defaultIdx = find(strcmp(choices, current), 1);
if isempty(defaultIdx), defaultIdx = 1; end

sel = listdlg('PromptString', {sprintf('Select input source for %s', label)}, ...
              'SelectionMode', 'single', ...
              'ListString',    choices, ...
              'InitialValue',  defaultIdx, ...
              'ListSize',      [320 160], ...
              'Name',          [label ' input source']);
if isempty(sel), return; end  % keep current

try
    src.InputSource = choices{sel};
    fprintf('%s: InputSource = %s\n', label, choices{sel});
catch err
    warning('%s: could not set InputSource to %s (%s).', label, choices{sel}, err.message);
end
end