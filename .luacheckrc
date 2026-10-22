-- Based on KOReader's own .luacheckrc
unused_args = false
std = "luajit"
-- ignore implicit self
self = false

globals = {
    "G_reader_settings",
    "G_defaults",
}

ignore = {
    "631", -- Line is too long (KOReader does not enforce this either)
}
