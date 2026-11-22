using System.ComponentModel;
using System.Text.Json.Serialization;

namespace CustomHUD.Config;

// The layout each plugin's menus draw in, by name (BuiltInLayouts, or the operator's MenuLayouts).
// A class rather than a dictionary: SW2 back-fills a property a later release adds, never a key.
public sealed class MenuChoices
{
    public PluginMenuChoice WeaponSkins { get; set; } = new() { Mouse = "menu_skins_mouse_v2", Keyboard = "menu_list_skins_v2" };
    public PluginMenuChoice ShopCore { get; set; } = PluginMenuChoice.Locker();
    public PluginMenuChoice MapChooser { get; set; } = PluginMenuChoice.Locker();
    // Ranks_WeaponStats, Ranks_CustomCombos and Ranks_Prestige follow it: they open under its Statistics.
    public PluginMenuChoice Ranks { get; set; } = PluginMenuChoice.Locker();
    public PluginMenuChoice VIPCore { get; set; } = PluginMenuChoice.Locker();
    public PluginMenuChoice Admins { get; set; } = PluginMenuChoice.Locker();
    public PluginMenuChoice MixScrims { get; set; } = PluginMenuChoice.Locker();

    [Description("Every other plugin.")]
    public MenuChoice Other { get; set; } = new() { Mouse = "menu_list_mouse_v2", Keyboard = "menu_list_v2" };

    public MenuChoice For(string plugin) => plugin switch
    {
        nameof(WeaponSkins) => WeaponSkins,
        nameof(ShopCore) => ShopCore,
        nameof(MapChooser) => MapChooser,
        nameof(Ranks) => Ranks,
        nameof(VIPCore) => VIPCore,
        nameof(Admins) => Admins,
        nameof(MixScrims) => MixScrims,
        _ => Other,
    };
}

// Keyboard is every keyboard mode: buttons, wasd and numbers. An empty name passes the mode on: a
// MenuOverrides entry's to its plugin's choice, a plugin's to its built-in default.
public class MenuChoice
{
    public string Mouse { get; set; } = "";
    public string Keyboard { get; set; } = "";

    public string? For(bool mouse) => (mouse ? Mouse : Keyboard)?.Trim() is { Length: > 0 } name ? name : null;
}

// A supported plugin's entry: Other's and the MenuOverrides entries have no mode of their own.
// Order 1 writes these after Mouse and Keyboard, where SW2 back-fills them: System.Text.Json writes a
// derived class's own properties first.
public sealed class PluginMenuChoice : MenuChoice
{
    [Description("Mode this plugin's menus open in: 0 = the starting mode MenuConfig sets, 1 = wasd, 2 = buttons, 3 = numbers, 4 = mouse.")]
    [JsonPropertyOrder(1)]
    public LayoutNavMode LayoutDefaultNavMode { get; set; }

    [Description("true = a player's !setnav choice wins over LayoutDefaultNavMode, false = this plugin's menus ignore it.")]
    [JsonPropertyOrder(1)]
    public bool AllowPreferenceOverride { get; set; } = true;

    public static PluginMenuChoice Locker() => new() { Mouse = "menu_locker_v2", Keyboard = "menu_list_v2" };

    // Null for Default, and for a number no mode has, which Problems() reports.
    internal NavMode? Mode() => LayoutDefaultNavMode switch
    {
        LayoutNavMode.Wasd => NavMode.Wasd,
        LayoutNavMode.Buttons => NavMode.Buttons,
        LayoutNavMode.Numbers => NavMode.Numbers,
        LayoutNavMode.Mouse => NavMode.Mouse,
        _ => null,
    };
}

// config.jsonc holds these by number, as SW2 writes an enum, so they are never renumbered.
public enum LayoutNavMode
{
    Default = 0,
    Wasd = 1,
    Buttons = 2,
    Numbers = 3,
    Mouse = 4,
}
