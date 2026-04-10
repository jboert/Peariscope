#pragma once

#include <QAbstractListModel>
#include <QString>
#include <QVector>

namespace peariscope {

struct RecentConnection {
    QString code;
    QString name;
    QString timestamp;
    bool pinned = false;
    int onlineStatus = 0;  // 0=unknown, 1=online, -1=offline
};

class RecentConnectionsModel : public QAbstractListModel {
    Q_OBJECT
public:
    enum Roles {
        CodeRole = Qt::UserRole + 1,
        NameRole,
        TimestampRole,
        PinnedRole,
        OnlineStatusRole,
        DisplayLabelRole,
    };

    explicit RecentConnectionsModel(QObject* parent = nullptr)
        : QAbstractListModel(parent) {}

    int rowCount(const QModelIndex& parent = QModelIndex()) const override {
        Q_UNUSED(parent);
        return static_cast<int>(items_.size());
    }

    QVariant data(const QModelIndex& index, int role) const override {
        if (!index.isValid() || index.row() >= static_cast<int>(items_.size()))
            return {};
        const auto& item = items_[index.row()];
        switch (role) {
        case CodeRole:         return item.code;
        case NameRole:         return item.name;
        case TimestampRole:    return item.timestamp;
        case PinnedRole:       return item.pinned;
        case OnlineStatusRole: return item.onlineStatus;
        case DisplayLabelRole: {
            QString label = item.name.isEmpty() ? item.code : item.name;
            if (label.length() > 35) label = label.left(32) + "...";
            return label;
        }
        default: return {};
        }
    }

    QHash<int, QByteArray> roleNames() const override {
        return {
            {CodeRole, "code"},
            {NameRole, "name"},
            {TimestampRole, "timestamp"},
            {PinnedRole, "pinned"},
            {OnlineStatusRole, "onlineStatus"},
            {DisplayLabelRole, "displayLabel"},
        };
    }

    void setItems(const QVector<RecentConnection>& items) {
        beginResetModel();
        items_ = items;
        endResetModel();
    }

    const QVector<RecentConnection>& items() const { return items_; }

    void updateOnlineStatus(const QString& code, int status) {
        for (int i = 0; i < items_.size(); ++i) {
            if (items_[i].code == code) {
                items_[i].onlineStatus = status;
                emit dataChanged(index(i), index(i), {OnlineStatusRole});
            }
        }
    }

private:
    QVector<RecentConnection> items_;
};

} // namespace peariscope
