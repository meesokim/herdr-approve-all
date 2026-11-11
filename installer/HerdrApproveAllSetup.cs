using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Threading;

namespace HerdrApproveAllSetup
{
    internal static class Program
    {
        private const string HerdrInstallPs1Url = "https://herdr.dev/install.ps1";
        private const string HerdrInstallCmdUrl = "https://herdr.dev/install.cmd";
        private const string PluginId = "renkoya1.approve-all";

        private static readonly string[] EmbeddedFiles = new string[]
        {
            "herdr-plugin.toml",
            "README.md",
            "scripts/dispatch",
            "scripts/dispatch.cmd",
            "scripts/dispatch.exe",
            "scripts/approve-windows.ps1",
            "scripts/lib.sh",
            "scripts/approve-blocked.sh",
            "scripts/auto-toggle.sh",
            "scripts/on-status-changed.sh"
        };

        private static int Main(string[] args)
        {
            Console.OutputEncoding = Encoding.UTF8;
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2

            bool skipHerdrUpdate = false;
            foreach (string arg in args)
            {
                if (string.Equals(arg, "--skip-herdr-update", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(arg, "--silent", StringComparison.OrdinalIgnoreCase))
                {
                    skipHerdrUpdate = true;
                }
            }

            try
            {
                WriteHeader("Herdr + herdr-approve-all All-in-One Setup (Windows)");

                // 1. Install or update Herdr
                string herdrExe = EnsureHerdrInstalled(skipHerdrUpdate);
                Console.WriteLine("[OK] Herdr binary: " + herdrExe);

                // 2. Stop any running monitor process before writing plugin files
                StopExistingMonitor();

                // 3. Extract embedded plugin source code to local plugin directory
                string targetPluginDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "herdr",
                    "plugins-local",
                    PluginId
                );
                ExtractEmbeddedPluginFiles(targetPluginDir);
                Console.WriteLine("[OK] Embedded plugin files extracted to: " + targetPluginDir);

                // Also sync to any existing github-installations directory if present
                SyncExistingGithubInstallations(targetPluginDir);

                // 4. Create auto-approve flag before linking so Herdr daemon's [[startup]] hook
                // immediately launches dispatch.exe monitor in the Herdr daemon's own session
                PrepareAutoApproveFlag();

                // 5. Register local directory directly as plugin via `herdr plugin link`
                RegisterLocalPluginInHerdr(herdrExe, targetPluginDir);

                // 6. Verify background monitor is active (or start it if Herdr daemon is not running)
                EnableAutoApproveWindows(herdrExe, targetPluginDir);

                WriteHeader("Setup Completed Successfully! (auto-on-windows is ACTIVE)");
                return 0;
            }
            catch (Exception ex)
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.Error.WriteLine("[ERROR] Setup failed: " + ex.Message);
                Console.ResetColor();
                return 1;
            }
        }

        private static void WriteHeader(string title)
        {
            Console.ForegroundColor = ConsoleColor.Cyan;
            Console.WriteLine("================================================================");
            Console.WriteLine(" " + title);
            Console.WriteLine("================================================================");
            Console.ResetColor();
        }

        private static string FindHerdrExe()
        {
            string localBin = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "Herdr", "bin", "herdr.exe"
            );
            if (File.Exists(localBin))
            {
                return localBin;
            }

            string pathEnv = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (string dir in pathEnv.Split(Path.PathSeparator))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                try
                {
                    string candidate = Path.Combine(dir.Trim(), "herdr.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
            return null;
        }

        private static string EnsureHerdrInstalled(bool skipUpdate)
        {
            string herdrExe = FindHerdrExe();
            if (herdrExe != null)
            {
                Console.WriteLine("[1/4] Existing Herdr found: " + herdrExe);
                if (!skipUpdate)
                {
                    Console.WriteLine("      Updating Herdr to latest version (herdr update)...");
                    RunProcess(herdrExe, "update", 120000, false);
                    herdrExe = FindHerdrExe() ?? herdrExe;
                }
            }
            else
            {
                Console.WriteLine("[1/4] Herdr not found. Installing latest Herdr for Windows...");
                string tempDir = Path.Combine(Path.GetTempPath(), "herdr-setup-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(tempDir);
                try
                {
                    string ps1Path = Path.Combine(tempDir, "install.ps1");
                    bool installed = false;
                    try
                    {
                        DownloadFile(HerdrInstallPs1Url, ps1Path);
                        string psExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                        int code = RunProcess(psExe, "-NoProfile -ExecutionPolicy Bypass -File \"" + ps1Path + "\"", 180000, true);
                        installed = (code == 0);
                    }
                    catch
                    {
                        installed = false;
                    }

                    if (!installed)
                    {
                        string cmdPath = Path.Combine(tempDir, "install.cmd");
                        DownloadFile(HerdrInstallCmdUrl, cmdPath);
                        RunProcess("cmd.exe", "/c \"" + cmdPath + "\"", 180000, true);
                    }
                }
                finally
                {
                    try { Directory.Delete(tempDir, true); } catch { }
                }

                herdrExe = FindHerdrExe();
                if (herdrExe == null)
                {
                    throw new InvalidOperationException("Herdr installation finished, but herdr.exe was not found in PATH or %LOCALAPPDATA%\\Programs\\Herdr\\bin.");
                }
            }

            string herdrBinDir = Path.GetDirectoryName(herdrExe);
            string currentPath = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            if (!string.IsNullOrEmpty(herdrBinDir) && currentPath.IndexOf(herdrBinDir, StringComparison.OrdinalIgnoreCase) < 0)
            {
                Environment.SetEnvironmentVariable("PATH", herdrBinDir + Path.PathSeparator + currentPath);
            }

            return herdrExe;
        }

        private static void StopExistingMonitor()
        {
            string pidFile = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "herdr", "plugins", PluginId, "monitor.pid"
            );
            if (File.Exists(pidFile))
            {
                try
                {
                    string raw = File.ReadAllText(pidFile).Trim();
                    int pid;
                    if (int.TryParse(raw, out pid) && pid > 0)
                    {
                    try
                    {
                        Process proc = Process.GetProcessById(pid);
                        if (proc.ProcessName.IndexOf("powershell", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            proc.ProcessName.IndexOf("dispatch", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            proc.Kill();
                            proc.WaitForExit(2000);
                        }
                    }
                    catch { }
                }
                File.Delete(pidFile);
                }
                catch { }
            }
            try
            {
                foreach (Process p in Process.GetProcessesByName("dispatch"))
                {
                    try
                    {
                        p.Kill();
                        p.WaitForExit(2000);
                    }
                    catch { }
                    finally { p.Dispose(); }
                }
            }
            catch { }
        }

        private static void ExtractEmbeddedPluginFiles(string targetPluginDir)
        {
            Console.WriteLine("[2/4] Extracting packaged plugin source files to local directory...");
            Assembly asm = Assembly.GetExecutingAssembly();
            Directory.CreateDirectory(targetPluginDir);
            Directory.CreateDirectory(Path.Combine(targetPluginDir, "scripts"));

            foreach (string relativePath in EmbeddedFiles)
            {
                string destPath = Path.Combine(targetPluginDir, relativePath.Replace('/', Path.DirectorySeparatorChar));
                string parent = Path.GetDirectoryName(destPath);
                if (!string.IsNullOrEmpty(parent))
                {
                    Directory.CreateDirectory(parent);
                }

                using (Stream resourceStream = asm.GetManifestResourceStream(relativePath))
                {
                    if (resourceStream == null)
                    {
                        throw new InvalidOperationException("Missing embedded resource: " + relativePath);
                    }
                    using (FileStream fs = new FileStream(destPath, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        resourceStream.CopyTo(fs);
                    }
                }
            }
        }

        private static void SyncExistingGithubInstallations(string sourcePluginDir)
        {
            string ghInstalls = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "herdr", "plugins", "github-installations"
            );
            if (!Directory.Exists(ghInstalls)) return;

            try
            {
                foreach (string dir in Directory.GetDirectories(ghInstalls, "renkoya1.approve-all*"))
                {
                    CopyDirectory(sourcePluginDir, dir);
                }
            }
            catch { }
        }

        private static void RegisterLocalPluginInHerdr(string herdrExe, string targetPluginDir)
        {
            Console.WriteLine("[3/4] Registering local directory as Herdr plugin (" + PluginId + ")...");

            // Remove any previous github-installed or stale entry first, then link the local directory
            RunProcess(herdrExe, "plugin remove " + PluginId, 15000, false);
            int linkCode = RunProcess(herdrExe, "plugin link \"" + targetPluginDir + "\" --enabled", 20000, true);
            if (linkCode != 0)
            {
                RunProcess(herdrExe, "plugin link \"" + targetPluginDir + "\"", 20000, true);
            }
            RunProcess(herdrExe, "plugin enable " + PluginId, 15000, false);
        }

        private static void PrepareAutoApproveFlag()
        {
            string configDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "herdr", "plugins", "config", PluginId
            );
            string stateDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "herdr", "plugins", PluginId
            );
            Directory.CreateDirectory(configDir);
            Directory.CreateDirectory(stateDir);

            string flagFile = Path.Combine(configDir, "auto-approve");
            if (!File.Exists(flagFile))
            {
                File.WriteAllText(flagFile, string.Empty, Encoding.ASCII);
            }
        }

        private static void EnableAutoApproveWindows(string herdrExe, string targetPluginDir)
        {
            Console.WriteLine("[4/4] Turning ON auto-on-windows and starting background monitor...");

            string configDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "herdr", "plugins", "config", PluginId
            );
            string stateDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "herdr", "plugins", PluginId
            );
            PrepareAutoApproveFlag();

            string pidFile = Path.Combine(stateDir, "monitor.pid");
            // Wait up to 2.5s for Herdr daemon's [[startup]] / [[events]] hook to start dispatch.exe monitor
            string activePid = WaitForMonitorPid(pidFile, 16);

            if (string.IsNullOrEmpty(activePid))
            {
                // Fallback when Herdr daemon is not running: start dispatch.exe on directly
                string dispatchExe = Path.Combine(targetPluginDir, "scripts", "dispatch.exe");
                if (File.Exists(dispatchExe))
                {
                    string args = "on -ConfigDir \"" + configDir + "\" -StateDir \"" + stateDir + "\" -HerdrBin \"" + herdrExe + "\"";
                    RunProcess(dispatchExe, args, 10000, false);
                }
                activePid = WaitForMonitorPid(pidFile, 20);
            }

            if (!string.IsNullOrEmpty(activePid))
            {
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine("[OK] Auto-approve monitor is active (PID: " + activePid + ")");
                Console.ResetColor();
            }
        }

        private static string WaitForMonitorPid(string pidFile, int attempts)
        {
            for (int i = 0; i < attempts; i++)
            {
                if (File.Exists(pidFile))
                {
                    try
                    {
                        string pidText = File.ReadAllText(pidFile).Trim();
                        int pid;
                        if (int.TryParse(pidText, out pid) && pid > 0)
                        {
                            try
                            {
                                Process proc = Process.GetProcessById(pid);
                                if (!proc.HasExited)
                                {
                                    return pidText;
                                }
                            }
                            catch { }
                        }
                    }
                    catch { }
                }
                Thread.Sleep(150);
            }
            return null;
        }

        private static void DownloadFile(string url, string destinationPath)
        {
            using (WebClient client = new WebClient())
            {
                client.Headers.Add("User-Agent", "herdr-approve-all-setup/1.0");
                if (WebRequest.DefaultWebProxy != null)
                {
                    client.Proxy = WebRequest.DefaultWebProxy;
                    client.Proxy.Credentials = CredentialCache.DefaultCredentials;
                }
                client.DownloadFile(url, destinationPath);
            }
        }

        private static void CopyDirectory(string sourceDir, string destinationDir)
        {
            Directory.CreateDirectory(destinationDir);
            foreach (string file in Directory.GetFiles(sourceDir))
            {
                string name = Path.GetFileName(file);
                File.Copy(file, Path.Combine(destinationDir, name), true);
            }
            foreach (string dir in Directory.GetDirectories(sourceDir))
            {
                string name = Path.GetFileName(dir);
                CopyDirectory(dir, Path.Combine(destinationDir, name));
            }
        }

        private static int RunProcess(string fileName, string arguments, int timeoutMs, bool streamOutput)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(fileName, arguments);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = !streamOutput;
                psi.RedirectStandardOutput = !streamOutput;
                psi.RedirectStandardError = !streamOutput;

                using (Process proc = Process.Start(psi))
                {
                    if (proc == null) return -1;
                    if (!proc.WaitForExit(timeoutMs))
                    {
                        try { proc.Kill(); } catch { }
                        return -2;
                    }
                    return proc.ExitCode;
                }
            }
            catch
            {
                return -1;
            }
        }
    }
}
