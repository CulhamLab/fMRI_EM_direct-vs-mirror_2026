function arduino_LED_set_colour(colour, p)

% no colour?
if ~exist("colour", "var")
    error("Must specify Red, Yellow, or Green")
end

% get parameters if not provided
if ~exist("p", "var")
    p = get_parameters;
end

% stop if ~p.ENABLE_ARDUINO
if ~p.ENABLE_ARDUINO
    warning("ENABLE_ARDUINO is false. Would have set LED colour to %s.", colour)
    return
end

% connect
global ard
if ~isobject(ard) | ~ard.isvalid
    ard = init_arduino('Mega 2560');
end

% turn on specified pin
switch colour
    case "Red"
        ard.analogWrite(p.ARDUINO.RED.PIN, p.ARDUINO.RED.BRIGHTNESS);
        ard.analogWrite(p.ARDUINO.GREEN.PIN, 0);

    case "Yellow"
        ard.analogWrite(p.ARDUINO.RED.PIN, p.ARDUINO.RED.BRIGHTNESS);
        ard.analogWrite(p.ARDUINO.GREEN.PIN, p.ARDUINO.GREEN.BRIGHTNESS);

    case "Green"
        ard.analogWrite(p.ARDUINO.RED.PIN, 0);
        ard.analogWrite(p.ARDUINO.GREEN.PIN, p.ARDUINO.GREEN.BRIGHTNESS);

    otherwise
        error({"Unknown colour: %s", colour})
end