--[[--
Converts article HTML into plain text for display in a TextViewer.

This module has no KOReader dependencies so it can be tested with plain LuaJIT.

@module koplugin.kofever.html
--]]

local Html = {}

-- Named entities beyond the XML basics that commonly appear in feed content.
local NAMED_ENTITIES = {
    amp = 38, lt = 60, gt = 62, quot = 34, apos = 39, nbsp = 160,
    iexcl = 161, cent = 162, pound = 163, curren = 164, yen = 165, brvbar = 166,
    sect = 167, uml = 168, copy = 169, ordf = 170, laquo = 171, ["not"] = 172,
    shy = 173, reg = 174, macr = 175, deg = 176, plusmn = 177, sup2 = 178,
    sup3 = 179, acute = 180, micro = 181, para = 182, middot = 183, cedil = 184,
    sup1 = 185, ordm = 186, raquo = 187, frac14 = 188, frac12 = 189, frac34 = 190,
    iquest = 191, times = 215, divide = 247,
    Agrave = 192, Aacute = 193, Acirc = 194, Atilde = 195, Auml = 196, Aring = 197,
    AElig = 198, Ccedil = 199, Egrave = 200, Eacute = 201, Ecirc = 202, Euml = 203,
    Igrave = 204, Iacute = 205, Icirc = 206, Iuml = 207, ETH = 208, Ntilde = 209,
    Ograve = 210, Oacute = 211, Ocirc = 212, Otilde = 213, Ouml = 214, Oslash = 216,
    Ugrave = 217, Uacute = 218, Ucirc = 219, Uuml = 220, Yacute = 221, THORN = 222,
    szlig = 223, agrave = 224, aacute = 225, acirc = 226, atilde = 227, auml = 228,
    aring = 229, aelig = 230, ccedil = 231, egrave = 232, eacute = 233, ecirc = 234,
    euml = 235, igrave = 236, iacute = 237, icirc = 238, iuml = 239, eth = 240,
    ntilde = 241, ograve = 242, oacute = 243, ocirc = 244, otilde = 245, ouml = 246,
    oslash = 248, ugrave = 249, uacute = 250, ucirc = 251, uuml = 252, yacute = 253,
    thorn = 254, yuml = 255, OElig = 338, oelig = 339, Scaron = 352, scaron = 353,
    Yuml = 376, fnof = 402, circ = 710, tilde = 732,
    ensp = 8194, emsp = 8195, thinsp = 8201, zwnj = 8204, zwj = 8205,
    ndash = 8211, mdash = 8212, lsquo = 8216, rsquo = 8217, sbquo = 8218,
    ldquo = 8220, rdquo = 8221, bdquo = 8222, dagger = 8224, Dagger = 8225,
    bull = 8226, hellip = 8230, permil = 8240, prime = 8242, Prime = 8243,
    lsaquo = 8249, rsaquo = 8250, euro = 8364, trade = 8482,
    larr = 8592, uarr = 8593, rarr = 8594, darr = 8595, harr = 8596,
    minus = 8722, le = 8804, ge = 8805, ne = 8800, infin = 8734,
}

-- Elements whose content is never shown.
local DROPPED_ELEMENTS = { "script", "style", "head", "noscript", "template", "svg", "iframe", "object" }

-- Elements that start and end a paragraph (blank line around them).
local PARAGRAPH_ELEMENTS = {
    p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    blockquote = true, ul = true, ol = true, dl = true, table = true, figure = true,
    pre = true, hr = true,
}

-- Elements that only force a line break.
local LINE_ELEMENTS = {
    div = true, section = true, article = true, header = true, footer = true,
    aside = true, nav = true, main = true, tr = true, dt = true, dd = true,
    figcaption = true, caption = true, address = true, details = true, summary = true,
}

local function codepointToUtf8(c)
    if not c or c < 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF) then
        return "\239\191\189" -- U+FFFD replacement character
    end
    if c < 0x80 then
        return string.char(c)
    elseif c < 0x800 then
        return string.char(0xC0 + math.floor(c / 0x40), 0x80 + c % 0x40)
    elseif c < 0x10000 then
        return string.char(0xE0 + math.floor(c / 0x1000),
                           0x80 + math.floor(c / 0x40) % 0x40,
                           0x80 + c % 0x40)
    else
        return string.char(0xF0 + math.floor(c / 0x40000),
                           0x80 + math.floor(c / 0x1000) % 0x40,
                           0x80 + math.floor(c / 0x40) % 0x40,
                           0x80 + c % 0x40)
    end
end

--- Decodes HTML character references in a single pass, so "&amp;lt;" becomes "&lt;" and not "<".
function Html.decodeEntities(text)
    return (text:gsub("&(#?[xX]?)(%w+);", function(prefix, name)
        local code
        if prefix == "#" then
            code = tonumber(name, 10)
        elseif prefix == "#x" or prefix == "#X" then
            code = tonumber(name, 16)
        elseif prefix == "" then
            code = NAMED_ENTITIES[name]
        end
        if not code then
            return nil -- leave unknown references untouched
        end
        if code == 160 then
            return " " -- a plain space reads better than NBSP on e-ink
        end
        return codepointToUtf8(code)
    end))
end

local function getAttribute(attrs, name)
    local value = attrs:match(name .. "%s*=%s*\"([^\"]*)\"")
        or attrs:match(name .. "%s*=%s*'([^']*)'")
        or attrs:match(name .. "%s*=%s*([^%s>]+)")
    return value
end

local function collapseWhitespace(text)
    return (text:gsub("[ \t\r\n\f\v]+", " "))
end

--- Converts an HTML fragment into readable plain text.
-- @string html HTML source (may be nil)
-- @treturn string plain text
function Html.toPlainText(html)
    if type(html) ~= "string" or html == "" then
        return ""
    end
    local text = html

    -- Normalise tag names to lowercase so the patterns below can be case sensitive.
    text = text:gsub("<(/?)(%a%w*)", function(slash, name)
        return "<" .. slash .. name:lower()
    end)

    -- Remove comments, CDATA wrappers and elements that never carry readable content.
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    text = text:gsub("<![^>]*>", "")
    text = text:gsub("<%?.-%?>", "")
    for _, tag in ipairs(DROPPED_ELEMENTS) do
        text = text:gsub("<" .. tag .. "[%s>/].-</" .. tag .. "%s*>", "")
        text = text:gsub("<" .. tag .. "[^>]*/>", "")
    end

    -- Keep <pre> blocks verbatim by swapping them out before whitespace is collapsed.
    local preformatted = {}
    text = text:gsub("<pre[^>]*>(.-)</pre%s*>", function(inner)
        inner = inner:gsub("<br[^>]*>", "\n")
        inner = inner:gsub("<[^>]*>", "")
        table.insert(preformatted, Html.decodeEntities(inner))
        -- the surrounding tags are kept so they become paragraph breaks below
        return "<pre>\1" .. #preformatted .. "\1</pre>"
    end)

    -- In HTML, runs of whitespace (including newlines) render as one space.
    text = collapseWhitespace(text)

    -- Images are not displayed, but alt text can carry meaning.
    text = text:gsub("<img(%s[^>]*)>", function(attrs)
        local alt = getAttribute(attrs, "alt")
        if alt and alt:match("%S") then
            return " [Image: " .. alt .. "] "
        end
        return " "
    end)

    -- Turn block-level tags into line breaks, and list items into bullets.
    text = text:gsub("<(/?)(%a%w*)[^>]*>", function(slash, name)
        if name == "br" then
            return "\n"
        elseif name == "li" then
            return slash == "" and "\n- " or ""
        elseif name == "td" or name == "th" then
            return " "
        elseif PARAGRAPH_ELEMENTS[name] then
            return "\n\n"
        elseif LINE_ELEMENTS[name] then
            return "\n"
        end
        return nil
    end)

    -- Remove every remaining tag, then decode entities.
    text = text:gsub("<[^>]*>", "")
    text = Html.decodeEntities(text)

    -- Tidy up: trim spaces around line breaks and limit blank lines to one.
    text = text:gsub(" *\n *", "\n")
    text = text:gsub("\n\n\n+", "\n\n")

    -- Restore preformatted blocks last, so their spacing is left alone.
    text = text:gsub("\1(%d+)\1", function(n)
        return preformatted[tonumber(n)]
    end)

    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

return Html
