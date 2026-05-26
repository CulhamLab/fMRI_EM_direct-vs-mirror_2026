function arduino_LED_all_on(p)

% get parameters if not provided
if ~exist("p", "var")
    p = get_parameters;
end

% stop if ~p.ENABLE_ARDUINO
if ~p.ENABLE_ARDUINO
    warning("ENABLE_ARDUINO is false. Would have turned all LEDs on.")
    return
end

% connect
global ard
if ~isobject(ard) | ~ard.isvalid
    ard = init_arduino('Mega 2560');
end

% turn on specified pin
for LED = string(fields(p.ARDUINO)')
    ard.analogWrite(p.ARDUINO.(LED).PIN, p.ARDUINO.(LED).BRIGHTNESS);
end

% display
disp("All LEDs on")