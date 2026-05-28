function arduino_LED_fixation_on(p)

% get parameters if not provided
if ~exist("p", "var")
    p = get_parameters;
end

% stop if ~p.ENABLE_ARDUINO
if ~p.ENABLE_ARDUINO
    warning("ENABLE_ARDUINO is false. Would have turned Fixation on.")
    return
end

% connect
global ard
if ~isobject(ard) | ~ard.isvalid
    ard = init_arduino('Mega 2560');
end

% turn on specified pin
ard.analogWrite(p.ARDUINO.FIXATION.PIN, p.ARDUINO.FIXATION.BRIGHTNESS);

% display
disp("Fixation LED on")