let common = require("core.common");
let as_string = common.as_string;

function is_valid_token(token) {
    token = trim(as_string(token));
    return length(token) > 0;
}

function validate_section(section) {
    if (!section)
        return { valid: false, error: "Section is missing" };

    let token = as_string(section.access_token || "");
    if (!is_valid_token(token))
        return { valid: false, error: "Missing or invalid FPTN access token" };

    return { valid: true };
}

return {
    is_valid_token,
    validate_section
};
