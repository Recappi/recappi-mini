using System;
using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;

namespace Recappi.Desktop;

public sealed class RecordingDateGroups : IValueConverter
{
    private readonly Func<DateTime> today;
    public RecordingDateGroups(Func<DateTime>? today = null) => this.today = today ?? (() => DateTime.Today);
    public static string Label(DateTimeOffset? timestamp, DateTime today)
    {
        if (timestamp is null) return "日期未知";
        var day = timestamp.Value.LocalDateTime.Date;
        if (day == today.Date) return "今天";
        if (day == today.Date.AddDays(-1)) return "昨天";
        return day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => Label(value is DateTimeOffset date ? date : null, today());
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
    public static ICollectionView Create(object source, string dateProperty, Func<DateTime>? today = null)
    {
        var view = CollectionViewSource.GetDefaultView(source);
        using (view.DeferRefresh())
        {
            view.SortDescriptions.Clear(); view.GroupDescriptions.Clear();
            view.SortDescriptions.Add(new(dateProperty, ListSortDirection.Descending));
            view.GroupDescriptions.Add(new PropertyGroupDescription(dateProperty, new RecordingDateGroups(today)));
        }
        return view;
    }
}
