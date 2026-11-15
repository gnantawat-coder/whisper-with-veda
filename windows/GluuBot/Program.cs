namespace GluuBot;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length == 4 && args[0] == "--selftest-engine") return SelfTest.Engine(args);
        if (args.Length == 2 && args[0] == "--selftest-ui") return SelfTest.Ui(args);

        using var single = new Mutex(true, "Local\\gluu-bot-windows-lite", out bool first);
        if (!first)
        {
            MessageBox.Show("gluu bot เปิดอยู่แล้ว — ดูไอคอนวงกลมดำตาฟ้าที่มุมขวาล่างของแถบงาน", "gluu bot");
            return 0;
        }
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => TrayApp.ReportCrash(e.Exception);
        Application.Run(new TrayApp());
        return 0;
    }
}
