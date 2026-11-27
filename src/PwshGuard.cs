using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

// dsh-pwsh-guard 1.x — DSH's PowerShell entry point.
//
// DSH runs every pwsh command through `@deepseek-ai/dsh-pwsh-sandbox`, whose
// `pwshPath` config points at this exe. DSH therefore always calls us with the
// exact argv it would have given PowerShell 7:
//
//   pwsh-guard.exe -NoLogo -NoProfile -NonInteractive -Command <preamble+command>
//
// This exe carries no policy. It dot-sources guard.shim.ps1 in front of that
// command and forwards the argv to the real PowerShell, so the shim decides
// inside the session where the delete targets are actually resolved.
// Log path, target limits and protected-root extras reach the shim through
// environment variables, so there is exactly one reader of guard.config.json.
//
// Language level: C# 5 (the .NET Framework csc.exe that ships with Windows).

internal sealed class GuardSettings
{
    public string ShimPath { get; set; }
    public string LogPath { get; set; }
    public int MaxTargets { get; set; }
    public bool DenyWildcard { get; set; }
    public List<string> ExtraRoots { get; set; }
    public List<string> PwshCandidates { get; set; }
    public string Source { get; set; }
    public string Error { get; set; }

    public GuardSettings()
    {
        MaxTargets = 20;
        DenyWildcard = true;
        ExtraRoots = new List<string>();
        PwshCandidates = new List<string>();
    }
}

internal static class Program
{
    internal const string Version = "1.0.0";
    private const string Tag = "[pwsh-guard]";
    private const int ExitNoPwsh = 4;
    private const int ExitInternal = 5;

    private static int Main(string[] args)
    {
        try
        {
            GuardSettings settings = LoadSettings();

            if (args.Length >= 1 && (args[0] == "--guard-info" || args[0] == "--guard-selftest"))
            {
                return PrintInfo(settings);
            }

            string shim = ResolvePath(settings.ShimPath);
            if (!File.Exists(shim))
            {
                Console.Error.WriteLine(Tag + " shim script missing: " + shim);
                Console.Error.WriteLine(Tag + " refusing to run unguarded; fix the path or reinstall (see README)");
                return ExitNoPwsh;
            }

            string real = ResolvePwsh(settings);
            if (real == null)
            {
                Console.Error.WriteLine(Tag + " no PowerShell executable found (checked " + string.Join(", ", settings.PwshCandidates.ToArray()) + " and PATH)");
                return ExitNoPwsh;
            }

            string[] forwarded = InjectShim(args, shim);
            return Run(real, forwarded, settings);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(Tag + " internal error: " + ex.Message);
            return ExitInternal;
        }
    }

    /// <summary>
    /// Prefix the -Command payload with a dot-source of the shim. Everything else
    /// (including a command without -Command) is forwarded untouched.
    /// </summary>
    internal static string[] InjectShim(string[] args, string shim)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], "-Command", StringComparison.OrdinalIgnoreCase)
                || string.Equals(args[i], "-c", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 >= args.Length) return args;
                string[] copy = new string[args.Length];
                Array.Copy(args, copy, args.Length);
                string quotedPath = shim.Replace("'", "''");
                copy[i + 1] = ". '" + quotedPath + "'; " + args[i + 1];
                return copy;
            }
        }
        return args;
    }

    private static int Run(string real, string[] args, GuardSettings settings)
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = real;
        start.UseShellExecute = false;
        start.CreateNoWindow = false;

        start.EnvironmentVariables["DSH_GUARD_LOG"] = ResolvePath(settings.LogPath);
        start.EnvironmentVariables["DSH_GUARD_MAX_TARGETS"] = settings.MaxTargets.ToString();
        start.EnvironmentVariables["DSH_GUARD_DENY_WILDCARD"] = settings.DenyWildcard ? "1" : "0";
        start.EnvironmentVariables["DSH_GUARD_EXTRA_ROOTS"] = string.Join(";", settings.ExtraRoots.ToArray());

        StringBuilder arguments = new StringBuilder();
        foreach (string arg in args)
        {
            if (arguments.Length > 0) arguments.Append(' ');
            arguments.Append(Quote(arg));
        }
        start.Arguments = arguments.ToString();

        using (Process child = Process.Start(start))
        {
            if (child == null)
            {
                Console.Error.WriteLine(Tag + " failed to start " + real);
                return ExitNoPwsh;
            }
            child.WaitForExit();
            return child.ExitCode;
        }
    }

    // ------------------------------------------------------------------ config

    private static GuardSettings LoadSettings()
    {
        GuardSettings settings = Defaults();
        string path = Path.Combine(BaseDirectory(), "guard.config.json");
        settings.Source = path;
        if (!File.Exists(path))
        {
            settings.Source = path + " (missing, using built-in defaults)";
            return settings;
        }
        try
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = 4 * 1024 * 1024;
            Dictionary<string, object> root = serializer.DeserializeObject(File.ReadAllText(path, new UTF8Encoding(false))) as Dictionary<string, object>;
            if (root == null) throw new FormatException("root must be a JSON object");

            if (root.ContainsKey("shimPath")) settings.ShimPath = Convert.ToString(root["shimPath"]);
            if (root.ContainsKey("logPath")) settings.LogPath = Convert.ToString(root["logPath"]);
            if (root.ContainsKey("maxTargets")) settings.MaxTargets = Convert.ToInt32(root["maxTargets"]);
            if (root.ContainsKey("denyWildcard")) settings.DenyWildcard = Convert.ToBoolean(root["denyWildcard"]);

            object[] extra = root.ContainsKey("extraProtectedRoots") ? root["extraProtectedRoots"] as object[] : null;
            if (extra != null)
            {
                settings.ExtraRoots = new List<string>();
                foreach (object item in extra)
                {
                    string text = Expand(Convert.ToString(item));
                    if (!string.IsNullOrEmpty(text)) settings.ExtraRoots.Add(text);
                }
            }

            object[] candidates = root.ContainsKey("pwshCandidates") ? root["pwshCandidates"] as object[] : null;
            if (candidates != null)
            {
                settings.PwshCandidates = new List<string>();
                foreach (object item in candidates)
                {
                    string text = Expand(Convert.ToString(item));
                    if (!string.IsNullOrEmpty(text)) settings.PwshCandidates.Add(text);
                }
            }
        }
        catch (Exception ex)
        {
            settings.Error = ex.Message;
        }
        return settings;
    }

    private static GuardSettings Defaults()
    {
        GuardSettings settings = new GuardSettings();
        settings.ShimPath = "guard.shim.ps1";
        settings.LogPath = Path.Combine("logs", "guard.jsonl");
        settings.PwshCandidates = new List<string>(new string[]
        {
            @"C:\Program Files\PowerShell\7\pwsh.exe",
            @"C:\Program Files\PowerShell\7-preview\pwsh.exe",
            Expand(@"%LOCALAPPDATA%\Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe"),
            Expand(@"%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"),
        });
        return settings;
    }

    // ------------------------------------------------------------------ lookup

    private static string ResolvePwsh(GuardSettings settings)
    {
        foreach (string candidate in settings.PwshCandidates)
        {
            if (!string.IsNullOrEmpty(candidate) && File.Exists(candidate)) return candidate;
        }
        // Never lose the tool because a machine keeps PowerShell somewhere else.
        string onPath = FindOnPath("pwsh.exe");
        if (onPath != null) return onPath;
        return FindOnPath("powershell.exe");
    }

    private static string FindOnPath(string fileName)
    {
        string path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path)) return null;
        foreach (string entry in path.Split(';'))
        {
            string dir = entry.Trim().Trim('"');
            if (dir.Length == 0) continue;
            try
            {
                string candidate = Path.Combine(dir, fileName);
                if (File.Exists(candidate)) return candidate;
            }
            catch
            {
                // Malformed PATH entries are not our problem.
            }
        }
        return null;
    }

    internal static string ResolvePath(string value)
    {
        if (string.IsNullOrEmpty(value)) return value;
        string expanded = Expand(value);
        if (Path.IsPathRooted(expanded)) return expanded;
        return Path.Combine(BaseDirectory(), expanded);
    }

    internal static string Expand(string value)
    {
        if (string.IsNullOrEmpty(value)) return value;
        return Environment.ExpandEnvironmentVariables(value);
    }

    internal static string BaseDirectory()
    {
        string path = ExecutablePath();
        if (string.IsNullOrEmpty(path)) return Environment.CurrentDirectory;
        string dir = Path.GetDirectoryName(path);
        return string.IsNullOrEmpty(dir) ? Environment.CurrentDirectory : dir;
    }

    internal static string ExecutablePath()
    {
        try { return System.Reflection.Assembly.GetExecutingAssembly().Location; }
        catch { return Process.GetCurrentProcess().MainModule.FileName; }
    }

    /// <summary>Windows CreateProcess argument quoting (CommandLineToArgvW rules).</summary>
    internal static string Quote(string value)
    {
        if (value.Length == 0) return "\"\"";
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        foreach (char ch in value)
        {
            if (ch == '\\') { backslashes++; continue; }
            if (ch == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
                continue;
            }
            sb.Append('\\', backslashes);
            backslashes = 0;
            sb.Append(ch);
        }
        sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    // -------------------------------------------------------------------- info

    private static int PrintInfo(GuardSettings settings)
    {
        string shim = ResolvePath(settings.ShimPath);
        string log = ResolvePath(settings.LogPath);
        Console.WriteLine("dsh-pwsh-guard " + Version);
        Console.WriteLine("exe            = " + ExecutablePath());
        Console.WriteLine("config         = " + settings.Source + (settings.Error == null ? "" : " (ERROR: " + settings.Error + ")"));
        Console.WriteLine("shim           = " + shim + (File.Exists(shim) ? "  [found]" : "  [MISSING]"));
        Console.WriteLine("log            = " + log);
        Console.WriteLine("maxTargets     = " + settings.MaxTargets);
        Console.WriteLine("denyWildcard   = " + settings.DenyWildcard);
        Console.WriteLine("extraRoots     = " + (settings.ExtraRoots.Count == 0 ? "(none)" : string.Join("; ", settings.ExtraRoots.ToArray())));
        Console.WriteLine("protected roots evaluated inside the session:");
        Console.WriteLine("  %USERPROFILE%, %APPDATA%, %LOCALAPPDATA%, %DSH_HOME%, <session cwd>, drive roots");
        Console.WriteLine("pwshCandidates:");
        foreach (string candidate in settings.PwshCandidates)
        {
            Console.WriteLine("  - " + candidate + (File.Exists(candidate) ? "  [found]" : "  [missing]"));
        }
        return 0;
    }
}
