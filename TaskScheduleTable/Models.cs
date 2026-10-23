using System.Text.Json.Serialization;

namespace TaskScheduleTable;

public sealed class TaskItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Type { get; set; } = "タスク";
    public string Title { get; set; } = "";
    public string Details { get; set; } = "";
    public string Url { get; set; } = "";
    public bool UrlEnabled { get; set; }
    public string Deadline { get; set; } = "";
    public bool DeadlineEnabled { get; set; }
    public bool DeadlineYearExplicit { get; set; }
    public bool DeadlineMetadataKnown { get; set; } = true;
    public string Created { get; set; } = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
    public string Updated { get; set; } = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");

    [JsonIgnore]
    public bool IsSchedule => Type == "予定";
}

public sealed class AppSettingsModel
{
    public double Left { get; set; } = 80;
    public double Top { get; set; } = 80;
    public double Width { get; set; } = 760;
    public double Height { get; set; } = 390;
    public double FontSize { get; set; } = 13;
    public bool Locked { get; set; }
    public bool Topmost { get; set; }
    public string BackgroundImagePath { get; set; } = "";
    public double BackgroundImageOpacity { get; set; } = 0.45;
    public double ReadabilityOverlayOpacity { get; set; } = 0.35;
    public string TextColor { get; set; } = "#00FF66";
    public string BackgroundColor { get; set; } = "#000000";
    public double VoiceVolume { get; set; } = 1.0;
    public double VoiceVolume { get; set; } = 1.0;
}

public sealed class NotificationState
{
    public List<string> Keys { get; set; } = [];
}
