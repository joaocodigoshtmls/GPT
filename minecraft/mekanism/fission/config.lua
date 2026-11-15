-- Temperatures in Celsius, tank levels as fractions (0..1), slopes per second.
-- Conservative observation policy, NOT a universal safety guarantee.
return {
  CONTROLLER_ID = nil, -- panel: reactor <ID> overrides this value
  PANEL_ID = nil,      -- controller: reactor-modem <ID> overrides this value
  REACTOR_NAME = nil,  -- nil: require exactly one compatible reactor; then pin it
  MODEM_CHANNEL = 43,
  BURN_STEP = 0.5,
  UI_REFRESH = 0.5,
  TELEMETRY_SECONDS = 0.5,
  TELEMETRY_STALE_SECONDS = 5,
  PACKET_MAX_AGE_SECONDS = 8,
  COMMAND_TIMEOUT_SECONDS = 8,
  SAMPLE_SECONDS = 1,
  POLL_SECONDS = 0.25,
  MAX_SAMPLE_GAP = 3,
  BOOT_GRACE_SECONDS = 10,
  TEMP_SCRAM_C = 600,
  TEMP_START_MAX_C = 350,
  DAMAGE_MAX = 0,
  COOLANT_MIN = 0.20,
  COOLANT_START_MIN = 0.30,
  FUEL_MIN = 0.10,
  FUEL_START_MIN = 0.25,
  HEATED_MAX = 0.85,
  HEATED_START_MAX = 0.50,
  WASTE_MAX = 0.75,
  WASTE_START_MAX = 0.50,
  TREND_WINDOW = 60,
  SHORT_WINDOW = 10,
  STABLE_SECONDS = 120,
  MEASURE_SECONDS = 600,
  TEST_TIMEOUT = 1800,
  PREDICT_SECONDS = 60,
  TEMP_SLOPE_MAX = 0.01,
  TANK_SLOPE_MAX = 0.000001,
  TEMP_RANGE_MAX = 3,
  TANK_DRIFT_MAX = 0.0005,
  TANK_RAW_NOISE = 2, -- mB: sensor quantization tolerance; not a capacity fraction
}
