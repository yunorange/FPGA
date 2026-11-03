#pragma once

#include <QMainWindow>
#include <QHostAddress>
#include <QTimer>
#include <QStringList>
#include <QByteArray>
#include <QQueue>
#include <QUdpSocket>
#include <memory>

class QComboBox;
class QLineEdit;
class QLabel;
class QPushButton;
class QSlider;
class QPlainTextEdit;
class QListWidget;
class QProgressBar;
class QCheckBox;
class QListWidgetItem;
class QFile;
class QSaveFile;

class MainWindow final : public QMainWindow
{
    Q_OBJECT
public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow() override;

private slots:
    void refreshInterfaces();
    void bindUdp();
    void unbindUdp();
    void readStatus();
    void readPendingDatagrams();
    void previousImage();
    void nextImage();
    void toggleAutoMode();
    void setTransitionMode(int index);
    void onBrightnessChanged(int value);
    void onContrastChanged(int value);
    void sendBrightness();
    void sendContrast();
    void onResponseTimeout();
    void onStatusPollTimeout();
    void pingFpga();
    void showArpTable();
    void clearLog();
    void refreshSdList();
    void uploadFiles();
    void downloadFiles();
    void deleteFiles();

private:
    enum class TransferKind { None, Listing, Upload, Download, Delete };
    enum class WaitKind { None, Status, ListEntry, UploadBegin, UploadData,
                          UploadEnd, DownloadData, DeleteEntry };

    bool isBound() const;
    bool localAddressExists(const QHostAddress &address) const;
    bool validateNetwork(QHostAddress &boardIp, QHostAddress &localIp,
                         quint16 &boardPort, quint16 &localPort);
    bool sendCommand(quint8 command, quint8 value, const QString &description,
                     bool expectStatus = true);
    bool sendFsPacket(const QByteArray &packet, WaitKind waitKind,
                      const QString &description);
    void handleStatus(const QByteArray &datagram);
    void handleFileResponse(const QByteArray &datagram);
    void updateStatus(quint8 brightness, quint8 contrast, quint8 transition,
                      quint8 imageIndex, quint8 fileCount, quint8 flags);
    void runDiagnostic(const QString &program, const QStringList &arguments,
                       const QString &description);
    void appendLog(const QString &message);
    void setNetworkState(const QString &message, bool error = false);
    void setFileControlsEnabled(bool enabled);
    void setTransferProgress(qint64 done, qint64 total);
    void finishTransfer(bool success, const QString &message);

    static QByteArray encodeFatName(const QString &name, bool *ok = nullptr);
    static QString decodeFatName(const QByteArray &bytes);
    static bool isValidFatName(const QString &name);
    static QString localSafeName(const QString &name);
    static QString formatFileSize(quint32 bytes);

    void requestListEntry();
    void startNextUpload();
    void sendNextUploadChunk();
    void startNextDownload();
    void requestDownloadChunk();
    void sendDeleteCurrent();
    void clearTransferResources();

    QUdpSocket *m_socket = nullptr;
    QTimer *m_responseTimer = nullptr;
    QTimer *m_statusPollTimer = nullptr;
    QHostAddress m_boardIp;
    QHostAddress m_localIp;
    quint16 m_boardPort = 5001;
    quint16 m_localPort = 5002;
    bool m_bound = false;
    bool m_waitingResponse = false;
    QString m_lastCommand;
    quint64 m_txCount = 0;
    quint64 m_rxCount = 0;

    QLineEdit *m_boardIpEdit = nullptr;
    QLineEdit *m_boardPortEdit = nullptr;
    QLineEdit *m_localIpEdit = nullptr;
    QLineEdit *m_localPortEdit = nullptr;
    QComboBox *m_interfaceBox = nullptr;
    QLabel *m_networkState = nullptr;
    QLabel *m_boardStatus = nullptr;
    QLabel *m_audioPolicy = nullptr;
    QLabel *m_brightnessValue = nullptr;
    QLabel *m_contrastValue = nullptr;
    QPushButton *m_bindButton = nullptr;
    QPushButton *m_unbindButton = nullptr;
    QPushButton *m_pingButton = nullptr;
    QPushButton *m_arpButton = nullptr;
    QPushButton *m_statusButton = nullptr;
    QPushButton *m_prevButton = nullptr;
    QPushButton *m_nextButton = nullptr;
    QPushButton *m_autoButton = nullptr;
    QSlider *m_brightnessSlider = nullptr;
    QSlider *m_contrastSlider = nullptr;
    QComboBox *m_transitionBox = nullptr;
    QCheckBox *m_autoPollCheck = nullptr;
    QListWidget *m_fileList = nullptr;
    QPushButton *m_listButton = nullptr;
    QPushButton *m_uploadButton = nullptr;
    QPushButton *m_downloadButton = nullptr;
    QPushButton *m_deleteButton = nullptr;
    QProgressBar *m_transferProgress = nullptr;
    QLabel *m_fileServiceInfo = nullptr;
    QPlainTextEdit *m_log = nullptr;

    TransferKind m_transferKind = TransferKind::None;
    WaitKind m_waitKind = WaitKind::None;
    QByteArray m_lastPacket;
    quint32 m_listCursor = 0;
    QStringList m_uploadPaths;
    QStringList m_downloadNames;
    QStringList m_deleteNames;
    QString m_currentName;
    QString m_downloadDirectory;
    std::unique_ptr<QFile> m_uploadFile;
    std::unique_ptr<QSaveFile> m_downloadFile;
    quint32 m_currentFileSize = 0;
    quint32 m_currentOffset = 0;
    quint64 m_transferDone = 0;
    quint64 m_transferTotal = 0;
    int m_queueIndex = 0;
    int m_retryCount = 0;
};
