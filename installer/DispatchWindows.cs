using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            return 1;
        }

        string mode = args[0];
        string configDir = Environment.GetEnvironmentVariable("HERDR_PLUGIN_CONFIG_DIR");
        if ((string.Equals(mode, "event", StringComparison.OrdinalIgnoreCase) ||
             string.Equals(mode, "startup", StringComparison.OrdinalIgnoreCase)) &&
            !string.IsNullOrEmpty(configDir))
        {
            string flagFile = Path.Combine(configDir, "auto-approve");
            if (!File.Exists(flagFile))
            {
                return 0;
            }
        }

        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(baseDir, "approve-windows.ps1");
        if (!File.Exists(scriptPath))
        {
            return 1;
        }

        string sysDir = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string psExe = Path.Combine(sysDir, @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(psExe))
        {
            psExe = "powershell.exe";
        }

        StringBuilder sb = new StringBuilder();
        sb.Append("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"");
        sb.Append(scriptPath);
        sb.Append("\"");
        foreach (string arg in args)
        {
            sb.Append(" \"");
            sb.Append(arg.Replace("\"", "\\\""));
            sb.Append("\"");
        }

        ProcessStartInfo psi = new ProcessStartInfo(psExe, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        using (Process proc = Process.Start(psi))
        {
            if (proc == null)
            {
                return 1;
            }
            proc.WaitForExit();
            return proc.ExitCode;
        }
    }
}
