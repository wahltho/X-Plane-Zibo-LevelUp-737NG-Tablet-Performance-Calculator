-- Stand-alone Lua 5.1-compatible performance core for the upstream Tablet.
-- The implementation mirrors the active private C++ takeoff and landing
-- calculators.  UI state, X-Plane datarefs and runway file I/O stay outside.

dofile("B738.tablet_perf_data.lua")
local data = B738_upstream_perf_data
local core = {}

local EPSILON = 0.0000001
local TAKEOFF_FLAPS = { 1, 5, 10, 15, 25 }
local decoded_cache = {}

local function near(a, b)
    return math.abs(a - b) < EPSILON
end

local function round(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return -math.floor(-value + 0.5)
end

local function key(...)
    local values = { ... }
    for index = 1, #values do
        values[index] = tostring(values[index])
    end
    return table.concat(values, ":")
end

local function decode_group(name, group_key)
    local cache_key = name .. "|" .. group_key
    if decoded_cache[cache_key] ~= nil then
        return decoded_cache[cache_key]
    end
    local encoded = data[name] and data[name][group_key]
    if encoded == nil then
        decoded_cache[cache_key] = false
        return nil
    end
    local values = {}
    for token in string.gmatch(encoded, "[^,;]+") do
        values[#values + 1] = tonumber(token)
    end
    decoded_cache[cache_key] = values
    return values
end

local function axis_add(axis, value)
    for index = 1, #axis do
        if near(axis[index], value) then
            return
        end
    end
    axis[#axis + 1] = value
end

local function bracket_axis(axis, value, clamp_low, clamp_high)
    if #axis == 0 then
        return nil
    end
    table.sort(axis)
    if value < axis[1] then
        if not clamp_low then
            return nil
        end
        return axis[1], axis[1], 0
    end
    if value > axis[#axis] then
        if not clamp_high then
            return nil
        end
        return axis[#axis], axis[#axis], 0
    end
    for index = 1, #axis do
        if near(value, axis[index]) then
            return axis[index], axis[index], 0
        end
        if index < #axis and value < axis[index + 1] then
            local low = axis[index]
            local high = axis[index + 1]
            return low, high, (value - low) / (high - low)
        end
    end
    return nil
end

local function grid2_lookup(rows, width, x_col, y_col, value_col, x, y)
    for offset = 1, #rows, width do
        if near(rows[offset + x_col - 1], x) and near(rows[offset + y_col - 1], y) then
            return rows[offset + value_col - 1]
        end
    end
    return nil
end

local function interpolate_grid2(rows, width, x_col, y_col, value_col, x, y,
        clamp_x_low, clamp_x_high, clamp_y_low, clamp_y_high)
    if rows == nil then
        return nil
    end
    local x_axis = {}
    local y_axis = {}
    for offset = 1, #rows, width do
        axis_add(x_axis, rows[offset + x_col - 1])
        axis_add(y_axis, rows[offset + y_col - 1])
    end
    local x_low, x_high, x_fraction = bracket_axis(x_axis, x, clamp_x_low, clamp_x_high)
    local y_low, y_high, y_fraction = bracket_axis(y_axis, y, clamp_y_low, clamp_y_high)
    if x_low == nil or y_low == nil then
        return nil
    end
    local ll = grid2_lookup(rows, width, x_col, y_col, value_col, x_low, y_low)
    local lh = grid2_lookup(rows, width, x_col, y_col, value_col, x_low, y_high)
    local hl = grid2_lookup(rows, width, x_col, y_col, value_col, x_high, y_low)
    local hh = grid2_lookup(rows, width, x_col, y_col, value_col, x_high, y_high)
    if ll == nil or lh == nil or hl == nil or hh == nil then
        return nil
    end
    local low = ll + (lh - ll) * y_fraction
    local high = hl + (hh - hl) * y_fraction
    return low + (high - low) * x_fraction
end

local function interpolate_grid1(rows, width, x_col, value_col, x, clamp_low, clamp_high)
    if rows == nil then
        return nil
    end
    local axis = {}
    for offset = 1, #rows, width do
        axis_add(axis, rows[offset + x_col - 1])
    end
    local low, high, fraction = bracket_axis(axis, x, clamp_low, clamp_high)
    if low == nil then
        return nil
    end
    local low_value = nil
    local high_value = nil
    for offset = 1, #rows, width do
        local row_x = rows[offset + x_col - 1]
        if near(row_x, low) then low_value = rows[offset + value_col - 1] end
        if near(row_x, high) then high_value = rows[offset + value_col - 1] end
    end
    if low_value == nil or high_value == nil then
        return nil
    end
    return low_value + (high_value - low_value) * fraction
end

local function grid3_lookup(rows, width, value_col, x, y, z)
    for offset = 1, #rows, width do
        if near(rows[offset], x) and near(rows[offset + 1], y) and near(rows[offset + 2], z) then
            return rows[offset + value_col - 1]
        end
    end
    return nil
end

local function interpolate_grid3(rows, width, value_col, x, y, z, strict_domain)
    if rows == nil then
        return nil
    end
    local x_axis = {}
    local y_axis = {}
    local z_axis = {}
    for offset = 1, #rows, width do
        axis_add(x_axis, rows[offset])
        axis_add(y_axis, rows[offset + 1])
        axis_add(z_axis, rows[offset + 2])
    end
    local x_low, x_high, x_fraction = bracket_axis(x_axis, x, true, not strict_domain)
    local y_low, y_high, y_fraction = bracket_axis(y_axis, y, false, true)
    local z_low, z_high, z_fraction = bracket_axis(z_axis, z, false, false)
    if x_low == nil or y_low == nil or z_low == nil then
        return nil
    end
    local xs = { x_low, x_high }
    local ys = { y_low, y_high }
    local zs = { z_low, z_high }
    local xy = {}
    for xi = 1, 2 do
        local z_values = {}
        for yi = 1, 2 do
            local low = grid3_lookup(rows, width, value_col, xs[xi], ys[yi], zs[1])
            local high = grid3_lookup(rows, width, value_col, xs[xi], ys[yi], zs[2])
            if low == nil or high == nil then
                return nil
            end
            z_values[yi] = low + (high - low) * z_fraction
        end
        xy[xi] = z_values[1] + (z_values[2] - z_values[1]) * y_fraction
    end
    return xy[1] + (xy[2] - xy[1]) * x_fraction
end

local function structural_mtow(variant)
    local values = {
        [0] = 79.015,
        [1] = 56.245,
        [2] = 70.080,
        [3] = 79.015,
        [4] = 79.015,
        [5] = 85.139,
    }
    return values[variant] or 0
end

function core.variant_from_aircraft_id(aircraft_variant)
    if aircraft_variant < 0 then return 0 end
    if aircraft_variant == 0 then return 3 end
    if aircraft_variant == 1 then return 4 end
    if aircraft_variant == 2 then return 2 end
    if aircraft_variant == 3 then return 1 end
    if aircraft_variant == 4 then return 5 end
    return nil
end

function core.full_thrust_rating(variant)
    local ratings = { [0] = 26, [1] = 22, [2] = 24, [3] = 26, [4] = 26, [5] = 27 }
    return ratings[variant]
end

function core.rating_family(variant)
    if variant == 0 then return { 26, 24, 22 } end
    if variant == 2 then return { 24, 22, 20 } end
    if variant == 5 then return { 27, 24, 22 } end
    local installed = core.full_thrust_rating(variant)
    if installed == nil then return {} end
    return { installed }
end

local function corrected_runway_length(input, dry)
    local slope = decode_group("slope", key(input.variant, dry and 1 or 0))
    local wind = decode_group("wind", key(input.variant, dry and 1 or 0))
    local slope_corrected = interpolate_grid2(
        slope, 3, 1, 2, 3, input.runway_length_m, input.runway_slope_percent,
        false, true, true, true)
    if slope_corrected == nil then
        return nil
    end
    return interpolate_grid2(
        wind, 3, 1, 2, 3, slope_corrected, input.headwind_kt,
        false, true, true, true)
end

local function apply_limit_corrections(input, rating, dry, field, value)
    local rows = decode_group("limit_corrections", key(input.variant, rating, dry and 1 or 0, input.flaps))
    if rows == nil or #rows < 6 then
        return nil
    end
    if not input.option_1 then value = value + rows[field and 1 or 2] end
    if input.option_2 then value = value + rows[field and 3 or 4] end
    if input.option_3 then value = value + rows[field and 5 or 6] end
    return value
end

local function field_limit(input, rating, dry, temperature)
    local runway_length = corrected_runway_length(input, dry)
    if runway_length == nil then
        return nil
    end
    local rows = decode_group("field", key(input.variant, rating, dry and 1 or 0, input.flaps))
    if rows == nil then
        return nil
    end
    local strict = rows[7] ~= 0
    local anchor = interpolate_grid3(rows, 7, 4, input.pressure_altitude_ft, runway_length, temperature, strict)
    local flap_weight = interpolate_grid3(rows, 7, 5, input.pressure_altitude_ft, runway_length, temperature, strict)
    local basis_weight = interpolate_grid3(rows, 7, 6, input.pressure_altitude_ft, runway_length, temperature, strict)
    if anchor == nil or flap_weight == nil or basis_weight == nil or basis_weight <= 0 then
        return nil
    end
    return apply_limit_corrections(input, rating, dry, true, anchor * flap_weight / basis_weight)
end

local function climb_limit(input, rating, dry, temperature)
    local rows = decode_group("climb", key(input.variant, rating, dry and 1 or 0, input.flaps))
    if rows == nil then
        return nil
    end
    local strict = rows[6] ~= 0
    local anchor = interpolate_grid2(rows, 6, 1, 2, 3,
        input.pressure_altitude_ft, temperature, true, not strict, false, false)
    local flap_weight = interpolate_grid2(rows, 6, 1, 2, 4,
        input.pressure_altitude_ft, temperature, true, not strict, false, false)
    local basis_weight = interpolate_grid2(rows, 6, 1, 2, 5,
        input.pressure_altitude_ft, temperature, true, not strict, false, false)
    if anchor == nil or flap_weight == nil or basis_weight == nil or basis_weight <= 0 then
        return nil
    end
    return apply_limit_corrections(input, rating, dry, false, anchor * flap_weight / basis_weight)
end

local function combined_limit(input, rating, dry, temperature)
    local field = field_limit(input, rating, dry, temperature)
    local climb = climb_limit(input, rating, dry, temperature)
    if field == nil or climb == nil then
        return nil
    end
    local result = math.min(field, climb, structural_mtow(input.variant))
    if result <= 0 then
        return nil
    end
    return result
end

local function speed_base(input, rating, dry)
    local rows = decode_group("speeds", key(input.variant, rating, dry and 1 or 0, input.flaps))
    if rows == nil then
        return nil
    end
    local values = {}
    for speed = 1, 3 do
        values[speed] = interpolate_grid1(rows, 4, 1, speed + 1,
            input.takeoff_weight_t, true, true)
        if values[speed] == nil then
            return nil
        end
    end
    return values
end

local function speed_adjustment(input, rating, dry, speed, temperature)
    local rows = decode_group("speed_adjustments", key(input.variant, rating, dry and 1 or 0, input.flaps, speed))
    return interpolate_grid2(rows, 3, 1, 2, 3, temperature, input.pressure_altitude_ft,
        true, false, true, false)
end

local function v1_parameter_adjustment(input, rating, dry, kind, parameter)
    local rows = decode_group("v1_adjustments", key(input.variant, rating, dry and 1 or 0, input.flaps, kind))
    return interpolate_grid2(rows, 3, 1, 2, 3, input.takeoff_weight_t, parameter,
        true, true, true, true)
end

local function mcg_speed(input, rating, dry, temperature)
    local rows = decode_group("mcg", key(input.variant, rating, dry and 1 or 0))
    return interpolate_grid2(rows, 3, 1, 2, 3, temperature, input.pressure_altitude_ft,
        true, false, true, false)
end

local function fill_speeds(result, input, rating, dry)
    local values = speed_base(input, rating, dry)
    if values == nil then return false end
    for speed = 0, 2 do
        local adjustment = speed_adjustment(input, rating, dry, speed, result.temperature_c)
        if adjustment == nil then return false end
        if adjustment >= -50 then values[speed + 1] = values[speed + 1] + adjustment end
    end
    local slope_adjustment = v1_parameter_adjustment(input, rating, dry, 0, input.runway_slope_percent)
    local wind_adjustment = v1_parameter_adjustment(input, rating, dry, 1, input.headwind_kt)
    local minimum_v1 = mcg_speed(input, rating, dry, result.temperature_c)
    if slope_adjustment == nil or wind_adjustment == nil or minimum_v1 == nil then return false end
    values[1] = values[1] + slope_adjustment + wind_adjustment
    values[1] = math.min(values[1], values[2])
    if minimum_v1 > 80 and minimum_v1 > values[1] then
        local shift = math.max(0, minimum_v1 - values[2])
        values[1] = minimum_v1
        values[2] = values[2] + shift
        values[3] = values[3] + shift
    end
    -- Match the stock FMC whole-knot contract so independently calculated
    -- EFB and FMC speeds do not differ only because of final rounding.
    result.v1 = math.floor(values[1])
    result.vr = math.floor(values[2])
    result.v2 = math.floor(values[3])
    return result.v1 <= result.vr and result.vr <= result.v2
end

local function full_n1(input, rating)
    local rows = decode_group("n1", key(input.variant, rating))
    local result = interpolate_grid2(rows, 3, 1, 2, 3, input.oat_c, input.pressure_altitude_ft,
        true, false, true, false)
    if result == nil then return nil end
    if not input.option_1 then
        local bleed = decode_group("n1_bleed", key(input.variant, rating))
        local correction = interpolate_grid1(bleed, 2, 1, 2,
            input.pressure_altitude_ft, true, true)
        if correction == nil then return nil end
        result = result + correction
    end
    return result
end

local function atm_maximum(input, rating)
    local rows = decode_group("atm_maximum", key(input.variant, rating))
    return interpolate_grid2(rows, 3, 1, 2, 3, input.oat_c, input.pressure_altitude_ft,
        true, false, true, false)
end

local function atm_minimum(input, rating)
    local rows = decode_group("atm_minimum", key(input.variant, rating))
    return interpolate_grid1(rows, 2, 1, 2, input.pressure_altitude_ft, true, true)
end

local function assumed_n1(input, rating, temperature)
    local rows = decode_group("atm_n1", key(input.variant, rating))
    local result = interpolate_grid2(rows, 3, 1, 2, 3, temperature, input.pressure_altitude_ft,
        true, false, true, false)
    if result == nil then return nil end
    local delta_rows = decode_group("atm_delta", key(input.variant, rating))
    local delta = interpolate_grid2(delta_rows, 3, 1, 2, 3,
        temperature - input.oat_c, input.oat_c, true, false, true, false)
    if delta == nil then return nil end
    if delta >= 0 then result = result - delta end
    if not input.option_1 then
        local bleed = decode_group("assumed_bleed", key(input.variant, rating))
        local correction = interpolate_grid1(bleed, 2, 1, 2,
            input.pressure_altitude_ft, true, true)
        if correction == nil then return nil end
        result = result + correction
    end
    return result
end

local function vref40(input)
    local rows = decode_group("vref40", key(input.variant))
    return interpolate_grid1(rows, 2, 1, 2, input.takeoff_weight_t, true, true)
end

local function trim(input, rating)
    local rows = decode_group("trim", key(input.variant, rating, input.flaps))
    return interpolate_grid2(rows, 3, 1, 2, 3,
        input.takeoff_weight_t, input.cg_percent, true, true, true, true)
end

function core.calculate_takeoff(input)
    local result = {
        windshear = false,
        full = { valid = false },
        assumed = { valid = false },
        maximum_takeoff_weight_t = 0,
        vref40 = 0,
        selected_flaps = 0,
        stabilizer_trim = -1,
    }
    local valid_flaps = input.flaps == 0
    for index = 1, #TAKEOFF_FLAPS do
        if input.flaps == TAKEOFF_FLAPS[index] then valid_flaps = true end
    end
    if not valid_flaps then return result end
    local ratings = {}
    local candidates = core.rating_family(input.variant)
    for index = 1, #candidates do
        if input.requested_rating == 0 or input.requested_rating == candidates[index] then
            ratings[#ratings + 1] = candidates[index]
        end
    end
    if #ratings == 0 then return result end

    local dry = input.dry
    local vref = vref40(input)
    if vref ~= nil then result.vref40 = round(vref) end
    local have_winner = false
    local winner_has_assumed = false
    local winner_n1 = math.huge
    local winner_limit = 0

    for flap_index = 1, #TAKEOFF_FLAPS do
        local flaps = TAKEOFF_FLAPS[flap_index]
        if input.flaps == 0 or input.flaps == flaps then
            for rating_index = 1, #ratings do
                local rating = ratings[rating_index]
                local candidate = {}
                for name, value in pairs(input) do candidate[name] = value end
                candidate.flaps = flaps
                local full_limit = combined_limit(candidate, rating, dry, candidate.oat_c)
                if full_limit ~= nil then
                    result.maximum_takeoff_weight_t = math.max(result.maximum_takeoff_weight_t, full_limit)
                    local full = { valid = false, rating = rating, temperature_c = candidate.oat_c }
                    if candidate.takeoff_weight_t <= full_limit then
                        full.n1_percent = full_n1(candidate, rating)
                        if full.n1_percent ~= nil and fill_speeds(full, candidate, rating, dry) then
                            full.valid = true
                        end
                    end
                    if full.valid then
                        local assumed = { valid = false, rating = rating }
                        local maximum_atm = atm_maximum(candidate, rating)
                        local minimum_atm = atm_minimum(candidate, rating)
                        if maximum_atm ~= nil and minimum_atm ~= nil then
                            minimum_atm = math.max(minimum_atm, candidate.oat_c)
                            local minimum = math.ceil(minimum_atm)
                            local maximum = math.floor(maximum_atm)
                            local selected_temperature = input.requested_assumed_temp_c or 0
                            if selected_temperature <= 0 then
                                selected_temperature = -1
                                for temperature = maximum, minimum, -1 do
                                    local assumed_limit = combined_limit(candidate, rating, dry, temperature)
                                    local n1 = assumed_n1(candidate, rating, temperature)
                                    if assumed_limit ~= nil and n1 ~= nil and
                                            candidate.takeoff_weight_t <= assumed_limit and n1 <= full.n1_percent then
                                        selected_temperature = temperature
                                        break
                                    end
                                end
                                if selected_temperature >= 0 and (input.requested_assumed_temp_c or 0) < 0 then
                                    selected_temperature = selected_temperature + input.requested_assumed_temp_c
                                end
                            end
                            if selected_temperature >= minimum and selected_temperature <= maximum then
                                local assumed_limit = combined_limit(candidate, rating, dry, selected_temperature)
                                assumed.temperature_c = selected_temperature
                                assumed.n1_percent = assumed_n1(candidate, rating, selected_temperature)
                                if assumed_limit ~= nil and assumed.n1_percent ~= nil and
                                        candidate.takeoff_weight_t <= assumed_limit and
                                        assumed.n1_percent <= full.n1_percent and
                                        fill_speeds(assumed, candidate, rating, dry) then
                                    assumed.valid = true
                                end
                            end
                        end

                        local has_assumed = assumed.valid
                        local selected_n1 = has_assumed and assumed.n1_percent or full.n1_percent
                        local replace = not have_winner or
                            (has_assumed and not winner_has_assumed) or
                            (has_assumed == winner_has_assumed and selected_n1 < winner_n1 - EPSILON) or
                            (has_assumed == winner_has_assumed and near(selected_n1, winner_n1) and full_limit > winner_limit + EPSILON)
                        if replace then
                            have_winner = true
                            winner_has_assumed = has_assumed
                            winner_n1 = selected_n1
                            winner_limit = full_limit
                            result.full = full
                            result.assumed = assumed
                            result.selected_flaps = flaps
                            result.stabilizer_trim = -1
                            if candidate.cg_percent ~= nil and candidate.cg_percent >= 0 then
                                local trim_value = trim(candidate, rating)
                                if trim_value ~= nil then result.stabilizer_trim = trim_value end
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

function core.calculate_landing(input)
    if input.variant == nil or input.variant < 1 or input.variant > 5 or
            (input.flaps ~= 15 and input.flaps ~= 30 and input.flaps ~= 40) or
            input.condition < 0 or input.condition > 3 or
            input.landing_weight_kg < 25000 or input.landing_weight_kg > 100000 or
            input.pressure_altitude_ft < -2000 or input.pressure_altitude_ft > 15000 or
            input.vref_add_kt < 0 or input.vref_add_kt > 30 or
            input.reversers < 0 or input.reversers > 2 then
        return nil, "INVALID INPUT"
    end
    local rows = decode_group("landing", key(input.variant, input.flaps, input.condition))
    if rows == nil or #rows ~= 5 * 18 then
        return nil, "NO TABLE"
    end
    local result = { air_distance_m = 304.8, distances = {} }
    for offset = 1, #rows, 18 do
        local brake = rows[offset]
        local reference_weight = rows[offset + 1]
        local weight_step = rows[offset + 2]
        local distance = rows[offset + 3]
        local weight_steps = (input.landing_weight_kg - reference_weight) / weight_step
        if weight_steps >= 0 then
            distance = distance + weight_steps * rows[offset + 4]
        else
            distance = distance + (-weight_steps) * rows[offset + 5]
        end
        if input.pressure_altitude_ft <= 8000 then
            distance = distance + (input.pressure_altitude_ft / 1000) * rows[offset + 6]
        else
            distance = distance + 8 * rows[offset + 6]
            distance = distance + ((input.pressure_altitude_ft - 8000) / 1000) * rows[offset + 7]
        end
        if input.headwind_kt >= 0 then
            distance = distance + (input.headwind_kt / 10) * rows[offset + 8]
        else
            distance = distance + (-input.headwind_kt / 10) * rows[offset + 9]
        end
        if input.runway_slope_percent >= 0 then
            distance = distance + input.runway_slope_percent * rows[offset + 11]
        else
            distance = distance + (-input.runway_slope_percent) * rows[offset + 10]
        end
        local isa = 15 - 1.98 * (input.pressure_altitude_ft / 1000)
        local temperature_delta = input.oat_c - isa
        if temperature_delta >= 0 then
            distance = distance + (temperature_delta / 10) * rows[offset + 12]
        else
            distance = distance + (-temperature_delta / 10) * rows[offset + 13]
        end
        distance = distance + (input.vref_add_kt / 5) * rows[offset + 14]
        if input.reversers == 1 then distance = distance + rows[offset + 15] end
        if input.reversers == 2 then distance = distance + rows[offset + 16] end
        if input.manual_speedbrakes then distance = distance + rows[offset + 17] end
        result.distances[brake] = math.max(304.8, distance)
    end
    return result
end

local VREF = {
    [3] = { weights = {38,42,46,50,54,58,62,66,70}, f30 = {106,112,117,122,127,132,137,141,146}, f40 = {104,110,115,120,125,130,135,139,144}, kilograms = true },
    [2] = { weights = {90,100,110,120,130,140,150,160,170}, f30 = {111,117,123,129,134,140,144,149,153}, f40 = {108,114,120,126,132,137,142,147,151} },
    [5] = { weights = {90,100,110,120,130,140,150,160,170}, f30 = {111,117,123,129,134,140,144,149,153}, f40 = {108,114,120,126,132,137,142,147,151} },
    [1] = { weights = {90,100,110,120,130,140,150,160,170,180}, f30 = {119,126,132,138,144,149,151,156,161,166}, f40 = {111,117,123,129,134,139,141,146,151,155} },
    [4] = { weights = {90,100,110,120,130,140,150,160,170,180}, f30 = {119,126,132,138,144,149,151,156,161,166}, f40 = {111,117,123,129,134,139,141,146,151,155} },
    [0] = { weights = {40,45,50,55,60,65,70,75,80,85}, f30 = {115,122,129,136,142,148,153,158,163,168}, f40 = {108,115,122,128,135,141,146,151,155,160}, kilograms = true },
}

local function interpolate_row(weights, values, weight)
    if weight <= weights[1] then return values[1] end
    if weight >= weights[#weights] then return values[#values] end
    for index = 2, #weights do
        if weight <= weights[index] then
            local low_weight = weights[index - 1]
            local high_weight = weights[index]
            local fraction = (weight - low_weight) / (high_weight - low_weight)
            return values[index - 1] + (values[index] - values[index - 1]) * fraction
        end
    end
    return nil
end

function core.calculate_vref(aircraft_variant, landing_weight_kg, flaps)
    local table_variant = aircraft_variant
    if aircraft_variant < 0 or aircraft_variant == 0 then table_variant = aircraft_variant < 0 and 0 or 0 end
    local table_data = VREF[table_variant]
    if table_data == nil then return nil end
    local weight_klb = landing_weight_kg * 2.20462262185 / 1000
    local working_weight = table_data.kilograms and (weight_klb / 2.20462262185) or weight_klb
    local vref40 = round(interpolate_row(table_data.weights, table_data.f40, working_weight))
    local vref30 = round(interpolate_row(table_data.weights, table_data.f30, working_weight))
    if vref30 > vref40 + 10 then vref30 = vref40 + 10 end
    if flaps == 15 then return vref40 + 20 end
    if flaps == 30 then return vref30 end
    return vref40
end

core.round = round
B738_upstream_perf_core = core
return core
