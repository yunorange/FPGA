#include "mainwindow.h"

#include <QAbstractSocket>
#include <QCheckBox>
#include <QComboBox>
#include <QDateTime>
#include <QFile>
#include <QFileDialog>
#include <QFileInfo>
#include <QGridLayout>
#include <QGroupBox>
#include <QAbstractItemView>
#include <QVector>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QListWidgetItem>
#include <QMessageBox>
#include <QNetworkInterface>
#include <QPlainTextEdit>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QSaveFile>
#include <QSignalBlocker>
#include <QSlider>
#include <QVBoxLayout>
#include <QWidget>
#include <QtEndian>
#include <QDir>
#include <QFileDevice>
#include <string>
#include <cstddef>

namespace {
constexpr quint8 CMD_PREVIOUS    = 0x01;
constexpr quint8 CMD_NEXT        = 0x02;
constexpr quint8 CMD_AUTO_TOGGLE = 0x03;
constexpr quint8 CMD_TRANSITION  = 0x04;
constexpr quint8 CMD_BRIGHTNESS  = 0x05;
constexpr quint8 CMD_CONTRAST    = 0x06;
constexpr quint8 CMD_READ_STATUS = 0x10;

constexpr quint8 FS_LIST_ENTRY   = 0x20;
constexpr quint8 FS_UPLOAD_BEGIN = 0x21;
constexpr quint8 FS_UPLOAD_DATA  = 0x22;
constexpr quint8 FS_UPLOAD_END   = 0x23;
constexpr quint8 FS_DOWNLOAD     = 0x24;
constexpr quint8 FS_DELETE       = 0x25;
constexpr quint8 FS_LIST_REPLY   = 0xA0;
constexpr quint8 FS_BEGIN_REPLY  = 0xA1;
constexpr quint8 FS_DATA_REPLY   = 0xA2;
constexpr quint8 FS_END_REPLY    = 0xA3;
constexpr quint8 FS_DOWN_REPLY   = 0xA4;
constexpr quint8 FS_DELETE_REPLY = 0xA5;

constexpr int CONTROL_PACKET_SIZE = 8;
constexpr int FILE_CHUNK_SIZE = 512;
constexpr int RESPONSE_TIMEOUT_MS = 3500;
constexpr int STATUS_POLL_MS = 3000;
constexpr int ROLE_NAME = Qt::UserRole + 1;
constexpr int ROLE_SIZE = Qt::UserRole + 2;
constexpr int ROLE_ATTR = Qt::UserRole + 3;

QString transitionName(int index)
{
    static const QStringList names = {
        QStringLiteral("淡入淡出"), QStringLiteral("分割"),
        QStringLiteral("直接切换"), QStringLiteral("揭开"),
        QStringLiteral("推入")
    };
    return (index >= 0 && index < names.size()) ? names.at(index)
                                                 : QStringLiteral("未知");
}

void appendBe16(QByteArray &a, quint16 v)
{
    a.append(char((v >> 8) & 0xff));
    a.append(char(v & 0xff));
}
void appendBe32(QByteArray &a, quint32 v)
{
    a.append(char((v >> 24) & 0xff));
    a.append(char((v >> 16) & 0xff));
    a.append(char((v >> 8) & 0xff));
    a.append(char(v & 0xff));
}
quint16 readBe16(const QByteArray &a, int p)
{
    return (quint16(quint8(a.at(p))) << 8) | quint16(quint8(a.at(p + 1)));
}
quint32 readBe32(const QByteArray &a, int p)
{
    return (quint32(quint8(a.at(p))) << 24) |
           (quint32(quint8(a.at(p + 1))) << 16) |
           (quint32(quint8(a.at(p + 2))) << 8) |
            quint32(quint8(a.at(p + 3)));
}

bool isSupportedMediaName(const QString &name)
{
    const QString suffix = QFileInfo(name).suffix();
    if (suffix.compare(QStringLiteral("bmp"), Qt::CaseInsensitive) == 0 ||
        suffix.compare(QStringLiteral("wav"), Qt::CaseInsensitive) == 0)
        return true;
    return name.compare(QStringLiteral("SUBTITLE.BIN"), Qt::CaseInsensitive) == 0;
}
}

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent),
      m_socket(new QUdpSocket(this)),
      m_responseTimer(new QTimer(this)),
      m_statusPollTimer(new QTimer(this))
{
    setWindowTitle(QStringLiteral("QHMU FPGA HDMI 图片/音频控制终端"));
    resize(1220, 790);
    setMinimumSize(1000, 680);

    m_responseTimer->setSingleShot(true);
    m_responseTimer->setInterval(RESPONSE_TIMEOUT_MS);
    m_statusPollTimer->setInterval(STATUS_POLL_MS);

    connect(m_socket, &QUdpSocket::readyRead, this, &MainWindow::readPendingDatagrams);
    connect(m_socket, &QAbstractSocket::errorOccurred, this,
            [this](QAbstractSocket::SocketError) {
        appendLog(QStringLiteral("UDP Socket 错误：%1").arg(m_socket->errorString()));
        if (m_socket->state() != QAbstractSocket::BoundState) {
            m_bound = false;
            setNetworkState(QStringLiteral("UDP 已断开"), true);
            setFileControlsEnabled(false);
        }
    });
    connect(m_responseTimer, &QTimer::timeout, this, &MainWindow::onResponseTimeout);
    connect(m_statusPollTimer, &QTimer::timeout, this, &MainWindow::onStatusPollTimeout);

    auto *central = new QWidget(this);
    setCentralWidget(central);
    auto *root = new QVBoxLayout(central);
    root->setContentsMargins(10, 8, 10, 8);
    root->setSpacing(6);

    auto *networkBox = new QGroupBox(QStringLiteral("网络连接（控制帧 8 字节；文件管理使用扩展 UDP 帧）"));
    auto *networkGrid = new QGridLayout(networkBox);
    m_boardIpEdit = new QLineEdit(QStringLiteral("192.168.240.2"));
    m_boardPortEdit = new QLineEdit(QStringLiteral("5001"));
    m_localIpEdit = new QLineEdit(QStringLiteral("192.168.240.100"));
    m_localPortEdit = new QLineEdit(QStringLiteral("5002"));
    m_interfaceBox = new QComboBox;
    m_interfaceBox->setMinimumWidth(230);
    m_bindButton = new QPushButton(QStringLiteral("连接/绑定"));
    m_unbindButton = new QPushButton(QStringLiteral("断开"));
    m_pingButton = new QPushButton(QStringLiteral("UDP探测"));
    m_arpButton = new QPushButton(QStringLiteral("查看 ARP"));
    m_statusButton = new QPushButton(QStringLiteral("读取状态"));
    m_networkState = new QLabel(QStringLiteral("尚未绑定"));
    m_networkState->setMinimumWidth(150);

    networkGrid->addWidget(new QLabel(QStringLiteral("板端 IP")), 0, 0);
    networkGrid->addWidget(m_boardIpEdit, 0, 1);
    networkGrid->addWidget(new QLabel(QStringLiteral("板端 UDP")), 0, 2);
    networkGrid->addWidget(m_boardPortEdit, 0, 3);
    networkGrid->addWidget(new QLabel(QStringLiteral("PC 本机 IP")), 0, 4);
    networkGrid->addWidget(m_localIpEdit, 0, 5);
    networkGrid->addWidget(new QLabel(QStringLiteral("本机 UDP")), 0, 6);
    networkGrid->addWidget(m_localPortEdit, 0, 7);
    networkGrid->addWidget(m_bindButton, 0, 8);
    networkGrid->addWidget(m_unbindButton, 0, 9);
    networkGrid->addWidget(new QLabel(QStringLiteral("网卡")), 1, 0);
    networkGrid->addWidget(m_interfaceBox, 1, 1, 1, 3);
    auto *refreshNicButton = new QPushButton(QStringLiteral("刷新网卡"));
    networkGrid->addWidget(refreshNicButton, 1, 4);
    networkGrid->addWidget(m_pingButton, 1, 5);
    networkGrid->addWidget(m_arpButton, 1, 6);
    networkGrid->addWidget(m_statusButton, 1, 7);
    networkGrid->addWidget(m_networkState, 1, 8, 1, 2);
    root->addWidget(networkBox);

    auto *body = new QHBoxLayout;
    root->addLayout(body, 1);

    auto *controlBox = new QGroupBox(QStringLiteral("图片播放与图像调节"));
    auto *controlLayout = new QVBoxLayout(controlBox);
    auto *navigation = new QHBoxLayout;
    m_prevButton = new QPushButton(QStringLiteral("上一张"));
    m_nextButton = new QPushButton(QStringLiteral("下一张"));
    m_autoButton = new QPushButton(QStringLiteral("手动/自动切换"));
    navigation->addWidget(m_prevButton);
    navigation->addWidget(m_nextButton);
    navigation->addWidget(m_autoButton);
    controlLayout->addLayout(navigation);

    auto *settings = new QGridLayout;
    m_brightnessSlider = new QSlider(Qt::Horizontal);
    m_brightnessSlider->setRange(0, 100);
    m_brightnessSlider->setValue(50);
    m_brightnessValue = new QLabel(QStringLiteral("50"));
    m_contrastSlider = new QSlider(Qt::Horizontal);
    m_contrastSlider->setRange(0, 100);
    m_contrastSlider->setValue(50);
    m_contrastValue = new QLabel(QStringLiteral("50"));
    settings->addWidget(new QLabel(QStringLiteral("亮度")), 0, 0);
    settings->addWidget(m_brightnessSlider, 0, 1);
    settings->addWidget(m_brightnessValue, 0, 2);
    settings->addWidget(new QLabel(QStringLiteral("对比度")), 1, 0);
    settings->addWidget(m_contrastSlider, 1, 1);
    settings->addWidget(m_contrastValue, 1, 2);
    m_transitionBox = new QComboBox;
    m_transitionBox->addItems({QStringLiteral("淡入淡出"), QStringLiteral("分割"),
                               QStringLiteral("直接切换"), QStringLiteral("揭开"),
                               QStringLiteral("推入")});
    settings->addWidget(new QLabel(QStringLiteral("转场模式")), 2, 0);
    settings->addWidget(m_transitionBox, 2, 1, 1, 2);
    controlLayout->addLayout(settings);

    m_boardStatus = new QLabel(QStringLiteral("板端状态：尚未读取"));
    m_boardStatus->setWordWrap(true);
    controlLayout->addWidget(m_boardStatus);
    m_audioPolicy = new QLabel(QStringLiteral("音频策略：等待读取板端状态。"));
    m_audioPolicy->setWordWrap(true);
    controlLayout->addWidget(m_audioPolicy);
    m_autoPollCheck = new QCheckBox(QStringLiteral("每 3 秒自动读取板端状态"));
    controlLayout->addWidget(m_autoPollCheck);
    controlLayout->addStretch();
    body->addWidget(controlBox, 3);

    auto *fileBox = new QGroupBox(QStringLiteral("SD 卡 FAT32 根目录文件管理（支持长文件名）"));
    auto *fileLayout = new QVBoxLayout(fileBox);
    m_fileServiceInfo = new QLabel(QStringLiteral(
        "只管理 FAT32 根目录；仅显示和管理 BMP 图片、WAV 音频及 SUBTITLE.BIN 字幕资源；支持长文件名/中文名，不进入子目录。列表采用分页读取，不设 32 个文件的固定上限。"));
    m_fileServiceInfo->setWordWrap(true);
    fileLayout->addWidget(m_fileServiceInfo);
    m_fileList = new QListWidget;
    m_fileList->setSelectionMode(QAbstractItemView::ExtendedSelection);
    fileLayout->addWidget(m_fileList, 1);
    auto *fileButtons1 = new QHBoxLayout;
    m_listButton = new QPushButton(QStringLiteral("刷新列表"));
    m_uploadButton = new QPushButton(QStringLiteral("电脑上传到 SD"));
    fileButtons1->addWidget(m_listButton);
    fileButtons1->addWidget(m_uploadButton);
    fileLayout->addLayout(fileButtons1);
    auto *fileButtons2 = new QHBoxLayout;
    m_downloadButton = new QPushButton(QStringLiteral("下载到电脑"));
    m_deleteButton = new QPushButton(QStringLiteral("删除选中文件"));
    fileButtons2->addWidget(m_downloadButton);
    fileButtons2->addWidget(m_deleteButton);
    fileLayout->addLayout(fileButtons2);
    m_transferProgress = new QProgressBar;
    m_transferProgress->setRange(0, 100);
    m_transferProgress->setValue(0);
    fileLayout->addWidget(m_transferProgress);
    body->addWidget(fileBox, 2);

    auto *logBox = new QGroupBox(QStringLiteral("通信与操作日志"));
    auto *logLayout = new QVBoxLayout(logBox);
    m_log = new QPlainTextEdit;
    m_log->setReadOnly(true);
    m_log->setMaximumBlockCount(1000);
    m_log->setFixedHeight(105);
    logLayout->addWidget(m_log);
    auto *logButtons = new QHBoxLayout;
    logButtons->addStretch();
    auto *clearButton = new QPushButton(QStringLiteral("清空日志"));
    logButtons->addWidget(clearButton);
    logLayout->addLayout(logButtons);
    root->addWidget(logBox, 0);

    connect(refreshNicButton, &QPushButton::clicked, this, &MainWindow::refreshInterfaces);
    connect(m_interfaceBox, qOverload<int>(&QComboBox::currentIndexChanged), this, [this](int index) {
        if (index >= 0) {
            const QString ip = m_interfaceBox->itemData(index).toString();
            if (!ip.isEmpty()) m_localIpEdit->setText(ip);
        }
    });
    connect(m_bindButton, &QPushButton::clicked, this, &MainWindow::bindUdp);
    connect(m_unbindButton, &QPushButton::clicked, this, &MainWindow::unbindUdp);
    connect(m_pingButton, &QPushButton::clicked, this, &MainWindow::pingFpga);
    connect(m_arpButton, &QPushButton::clicked, this, &MainWindow::showArpTable);
    connect(m_statusButton, &QPushButton::clicked, this, &MainWindow::readStatus);
    connect(m_prevButton, &QPushButton::clicked, this, &MainWindow::previousImage);
    connect(m_nextButton, &QPushButton::clicked, this, &MainWindow::nextImage);
    connect(m_autoButton, &QPushButton::clicked, this, &MainWindow::toggleAutoMode);
    connect(m_transitionBox, qOverload<int>(&QComboBox::currentIndexChanged), this, &MainWindow::setTransitionMode);
    connect(m_brightnessSlider, &QSlider::valueChanged, this, &MainWindow::onBrightnessChanged);
    connect(m_contrastSlider, &QSlider::valueChanged, this, &MainWindow::onContrastChanged);
    connect(m_brightnessSlider, &QSlider::sliderReleased, this, &MainWindow::sendBrightness);
    connect(m_contrastSlider, &QSlider::sliderReleased, this, &MainWindow::sendContrast);
    connect(m_autoPollCheck, &QCheckBox::toggled, this, [this](bool enabled) {
        if (enabled) { m_statusPollTimer->start(); readStatus(); }
        else m_statusPollTimer->stop();
    });
    connect(m_listButton, &QPushButton::clicked, this, &MainWindow::refreshSdList);
    connect(m_uploadButton, &QPushButton::clicked, this, &MainWindow::uploadFiles);
    connect(m_downloadButton, &QPushButton::clicked, this, &MainWindow::downloadFiles);
    connect(m_deleteButton, &QPushButton::clicked, this, &MainWindow::deleteFiles);
    connect(clearButton, &QPushButton::clicked, this, &MainWindow::clearLog);

    refreshInterfaces();
    m_unbindButton->setEnabled(false);
    setFileControlsEnabled(false);
    appendLog(QStringLiteral("程序启动：FPGA 192.168.240.2:5001，PC 192.168.240.100:5002。"));
    appendLog(QStringLiteral("亮度/对比度仅在滑块释放时发送。文件名按 UTF-16LE 传输，支持 FAT32 长文件名。"));
}

MainWindow::~MainWindow() = default;

void MainWindow::refreshInterfaces()
{
    const QString preferred = m_localIpEdit->text().trimmed();
    m_interfaceBox->clear();
    int preferredIndex = -1;
    for (const QNetworkInterface &iface : QNetworkInterface::allInterfaces()) {
        if (!iface.flags().testFlag(QNetworkInterface::IsUp) ||
            !iface.flags().testFlag(QNetworkInterface::IsRunning) ||
            iface.flags().testFlag(QNetworkInterface::IsLoopBack)) continue;
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            if (entry.ip().protocol() != QAbstractSocket::IPv4Protocol) continue;
            const QString ip = entry.ip().toString();
            m_interfaceBox->addItem(QStringLiteral("%1 [%2]").arg(iface.humanReadableName(), ip), ip);
            if (ip == preferred) preferredIndex = m_interfaceBox->count() - 1;
        }
    }
    if (preferredIndex >= 0) m_interfaceBox->setCurrentIndex(preferredIndex);
    else if (m_interfaceBox->count() > 0) {
        m_interfaceBox->setCurrentIndex(0);
        m_localIpEdit->setText(m_interfaceBox->itemData(0).toString());
    }
    appendLog(QStringLiteral("已刷新本机 IPv4 网卡列表，共 %1 个地址。").arg(m_interfaceBox->count()));
}

bool MainWindow::localAddressExists(const QHostAddress &address) const
{
    for (const QNetworkInterface &iface : QNetworkInterface::allInterfaces())
        for (const QNetworkAddressEntry &entry : iface.addressEntries())
            if (entry.ip() == address) return true;
    return false;
}

bool MainWindow::validateNetwork(QHostAddress &boardIp, QHostAddress &localIp,
                                 quint16 &boardPort, quint16 &localPort)
{
    bool ok1 = false, ok2 = false;
    boardIp = QHostAddress(m_boardIpEdit->text().trimmed());
    localIp = QHostAddress(m_localIpEdit->text().trimmed());
    const uint bp = m_boardPortEdit->text().toUInt(&ok1);
    const uint lp = m_localPortEdit->text().toUInt(&ok2);
    if (boardIp.isNull() || localIp.isNull() || boardIp.protocol() != QAbstractSocket::IPv4Protocol ||
        localIp.protocol() != QAbstractSocket::IPv4Protocol || !ok1 || !ok2 ||
        bp == 0 || bp > 65535 || lp == 0 || lp > 65535 || boardIp == localIp) {
        QMessageBox::warning(this, QStringLiteral("网络参数"), QStringLiteral("请检查 IPv4 地址和 UDP 端口。"));
        return false;
    }
    boardPort = quint16(bp);
    localPort = quint16(lp);
    return true;
}

bool MainWindow::isBound() const
{
    return m_bound && m_socket && m_socket->state() == QAbstractSocket::BoundState &&
           m_socket->localPort() == m_localPort;
}

void MainWindow::bindUdp()
{
    QHostAddress boardIp, localIp;
    quint16 boardPort = 0, localPort = 0;
    if (!validateNetwork(boardIp, localIp, boardPort, localPort)) return;
    if (!localAddressExists(localIp)) {
        QMessageBox::warning(this, QStringLiteral("本机 IP 不存在"),
                             QStringLiteral("所选网卡未配置 %1。请检查网卡 IPv4 设置。").arg(localIp.toString()));
        return;
    }
    m_socket->close();
    m_responseTimer->stop();
    m_waitingResponse = false;
    m_boardIp = boardIp; m_localIp = localIp; m_boardPort = boardPort; m_localPort = localPort;
    if (!m_socket->bind(m_localIp, m_localPort, QUdpSocket::DefaultForPlatform)) {
        setNetworkState(QStringLiteral("UDP 绑定失败"), true);
        appendLog(QStringLiteral("绑定失败：%1").arg(m_socket->errorString()));
        return;
    }
    m_bound = true;
    m_bindButton->setEnabled(false);
    m_unbindButton->setEnabled(true);
    setNetworkState(QStringLiteral("UDP 已绑定，等待 FPGA 响应"));
    setFileControlsEnabled(true);
    appendLog(QStringLiteral("UDP 本地绑定：%1:%2；目标：%3:%4")
                  .arg(m_localIp.toString()).arg(m_localPort).arg(m_boardIp.toString()).arg(m_boardPort));
    QTimer::singleShot(150, this, &MainWindow::readStatus);
}

void MainWindow::unbindUdp()
{
    m_responseTimer->stop();
    m_statusPollTimer->stop();
    m_waitingResponse = false;
    clearTransferResources();
    m_transferKind = TransferKind::None;
    m_waitKind = WaitKind::None;
    m_socket->close();
    m_bound = false;
    m_bindButton->setEnabled(true);
    m_unbindButton->setEnabled(false);
    setFileControlsEnabled(false);
    setNetworkState(QStringLiteral("UDP 已断开"));
    appendLog(QStringLiteral("已断开 UDP。"));
}

bool MainWindow::sendCommand(quint8 command, quint8 value, const QString &description, bool expectStatus)
{
    if (m_transferKind != TransferKind::None) {
        appendLog(QStringLiteral("文件传输期间暂不发送其他控制命令。"));
        return false;
    }
    if (!isBound()) {
        setNetworkState(QStringLiteral("请先绑定 UDP"), true);
        appendLog(QStringLiteral("发送取消：请先连接/绑定。"));
        return false;
    }
    QByteArray packet(CONTROL_PACKET_SIZE, char(0));
    packet[0] = char(command);
    packet[1] = char(value);
    const qint64 sent = m_socket->writeDatagram(packet, m_boardIp, m_boardPort);
    if (sent != packet.size()) {
        setNetworkState(QStringLiteral("UDP 发送失败"), true);
        appendLog(QStringLiteral("UDP 发送失败：%1").arg(m_socket->errorString()));
        return false;
    }
    ++m_txCount;
    appendLog(QStringLiteral("TX #%1 %2，%3 字节：%4").arg(m_txCount).arg(description).arg(packet.size())
                  .arg(QString::fromLatin1(packet.toHex(' '))));
    if (expectStatus) {
        m_waitingResponse = true;
        m_waitKind = WaitKind::Status;
        m_lastCommand = description;
        m_responseTimer->start();
    }
    return true;
}

bool MainWindow::sendFsPacket(const QByteArray &packet, WaitKind waitKind, const QString &description)
{
    if (!isBound() || packet.isEmpty() || packet.size() > 1400 || m_waitingResponse) return false;
    const qint64 sent = m_socket->writeDatagram(packet, m_boardIp, m_boardPort);
    if (sent != packet.size()) {
        appendLog(QStringLiteral("文件命令发送失败：%1").arg(m_socket->errorString()));
        finishTransfer(false, QStringLiteral("UDP 发送失败"));
        return false;
    }
    ++m_txCount;
    m_lastPacket = packet;
    m_waitKind = waitKind;
    m_waitingResponse = true;
    m_retryCount = 0;
    m_lastCommand = description;
    m_responseTimer->start();
    appendLog(QStringLiteral("TX #%1 %2，%3 字节").arg(m_txCount).arg(description).arg(packet.size()));
    return true;
}

void MainWindow::readStatus() { if (m_transferKind == TransferKind::None) sendCommand(CMD_READ_STATUS, 0, QStringLiteral("读取 FPGA 状态")); }
void MainWindow::previousImage() { sendCommand(CMD_PREVIOUS, 0, QStringLiteral("上一张图片")); }
void MainWindow::nextImage() { sendCommand(CMD_NEXT, 0, QStringLiteral("下一张图片")); }
void MainWindow::toggleAutoMode() { sendCommand(CMD_AUTO_TOGGLE, 0, QStringLiteral("切换手动/自动模式")); }
void MainWindow::setTransitionMode(int index)
{
    if (index >= 0 && index <= 4) sendCommand(CMD_TRANSITION, quint8(index), QStringLiteral("设置转场：%1").arg(transitionName(index)));
}
void MainWindow::onBrightnessChanged(int value) { m_brightnessValue->setText(QString::number(value)); }
void MainWindow::onContrastChanged(int value) { m_contrastValue->setText(QString::number(value)); }
void MainWindow::sendBrightness()
{
    const quint8 value = quint8(qBound(0, m_brightnessSlider->value(), 100));
    sendCommand(CMD_BRIGHTNESS, value, QStringLiteral("设置亮度 %1").arg(value));
}
void MainWindow::sendContrast()
{
    const quint8 value = quint8(qBound(0, m_contrastSlider->value(), 100));
    sendCommand(CMD_CONTRAST, value, QStringLiteral("设置对比度 %1").arg(value));
}

void MainWindow::readPendingDatagrams()
{
    while (m_socket->hasPendingDatagrams()) {
        QByteArray data;
        data.resize(int(m_socket->pendingDatagramSize()));
        QHostAddress sender; quint16 senderPort = 0;
        const qint64 n = m_socket->readDatagram(data.data(), data.size(), &sender, &senderPort);
        if (n < 0) { appendLog(QStringLiteral("读取 UDP 失败：%1").arg(m_socket->errorString())); continue; }
        data.resize(int(n));
        ++m_rxCount;
        appendLog(QStringLiteral("RX #%1 来自 %2:%3，%4 字节")
                      .arg(m_rxCount).arg(sender.toString()).arg(senderPort).arg(data.size()));
        if (sender != m_boardIp || senderPort != m_boardPort) {
            appendLog(QStringLiteral("忽略非目标 FPGA 的 UDP 数据。"));
            continue;
        }
        if (data.size() == CONTROL_PACKET_SIZE && quint8(data[0]) == 0x80) handleStatus(data);
        else if (!data.isEmpty() && quint8(data[0]) >= FS_LIST_REPLY && quint8(data[0]) <= FS_DELETE_REPLY)
            handleFileResponse(data);
        else appendLog(QStringLiteral("收到未知 UDP 响应帧。"));
    }
}

void MainWindow::handleStatus(const QByteArray &data)
{
    if (data.size() != CONTROL_PACKET_SIZE || quint8(data[0]) != 0x80 || quint8(data[1]) != 0x00) {
        appendLog(QStringLiteral("收到的数据不是有效的 8 字节状态帧。"));
        return;
    }
    const quint8 brightness = quint8(data[2]);
    const quint8 contrast = quint8(data[3]);
    const quint8 transition = quint8(data[4]);
    const quint8 imageIndex = quint8(data[5]);
    const quint8 fileCount = quint8(data[6]);
    const quint8 flags = quint8(data[7]);
    if (brightness > 100 || contrast > 100 || transition > 4) return;
    if (m_waitKind == WaitKind::Status) {
        m_waitingResponse = false;
        m_waitKind = WaitKind::None;
        m_responseTimer->stop();
    }
    setNetworkState(QStringLiteral("FPGA 通信正常"));
    updateStatus(brightness, contrast, transition, imageIndex, fileCount, flags);
}

void MainWindow::updateStatus(quint8 brightness, quint8 contrast, quint8 transition,
                              quint8 imageIndex, quint8 fileCount, quint8 flags)
{
    const QSignalBlocker b1(m_brightnessSlider), b2(m_contrastSlider), b3(m_transitionBox);
    m_brightnessSlider->setValue(brightness);
    m_contrastSlider->setValue(contrast);
    m_transitionBox->setCurrentIndex(transition);
    m_brightnessValue->setText(QString::number(brightness));
    m_contrastValue->setText(QString::number(contrast));
    const bool autoMode = flags & 0x01;
    const bool waitAudio = flags & 0x02;
    m_boardStatus->setText(QStringLiteral("板端状态：图片 %1 / %2；亮度 %3；对比度 %4；转场 %5；模式：%6")
        .arg(imageIndex).arg(fileCount).arg(brightness).arg(contrast)
        .arg(transitionName(transition)).arg(autoMode ? QStringLiteral("自动播放") : QStringLiteral("手动播放")));
    if (!autoMode) m_audioPolicy->setText(QStringLiteral("音频策略：手动模式，MUSXXXX.WAV 循环播放。"));
    else if (waitAudio) m_audioPolicy->setText(QStringLiteral("音频策略：自动变时，MUSXXXX.WAV 播放结束后切换图片。"));
    else m_audioPolicy->setText(QStringLiteral("音频策略：自动定时，AUDXXXX.WAV 播放，约 8 秒切换图片。"));
}

QByteArray MainWindow::encodeFatName(const QString &name, bool *ok)
{
    const bool valid = isValidFatName(name);
    if (ok) *ok = valid;
    if (!valid) return {};

    // QString stores UTF-16 code units. toStdU16String() is available in
    // Qt 6.9 and avoids the non-existent QString::toUtf16() API.
    const std::u16string utf16 = name.toStdU16String();
    QByteArray out;
    out.reserve(qsizetype(utf16.size() * 2));
    for (char16_t ch : utf16) {
        const quint16 value = quint16(ch);
        out.append(char(value & 0xff));
        out.append(char((value >> 8) & 0xff));
    }
    return out;
}

QString MainWindow::decodeFatName(const QByteArray &bytes)
{
    // FAT LFN stores UTF-16LE. Ignore a possible trailing odd byte rather
    // than reading beyond the received packet.
    const qsizetype units = bytes.size() / 2;
    std::u16string utf16(static_cast<std::size_t>(units), char16_t(0));
    for (qsizetype i = 0; i < units; ++i) {
        const quint16 lo = quint8(bytes.at(i * 2));
        const quint16 hi = quint8(bytes.at(i * 2 + 1));
        utf16[static_cast<std::size_t>(i)] = char16_t(lo | (hi << 8));
    }
    return QString::fromUtf16(utf16.data(), qsizetype(utf16.size()));
}

bool MainWindow::isValidFatName(const QString &name)
{
    if (name.isEmpty() || name == QStringLiteral(".") || name == QStringLiteral("..")) return false;
    if (name.endsWith(QLatin1Char(' ')) || name.endsWith(QLatin1Char('.'))) return false;
    // QString::size() counts UTF-16 code units, which is the FAT LFN limit.
    if (name.size() > 255) return false;
    static const QString invalid = QStringLiteral("\\/:*?\"<>|");
    for (QChar c : name) {
        if (c.unicode() < 0x20 || invalid.contains(c)) return false;
    }
    return true;
}

QString MainWindow::localSafeName(const QString &name)
{
    QString safe = name;
    for (QChar c : QStringLiteral("\\/:*?\"<>|")) safe.replace(c, QLatin1Char('_'));
    while (safe.endsWith(QLatin1Char(' ')) || safe.endsWith(QLatin1Char('.'))) safe.chop(1);
    if (safe.isEmpty()) safe = QStringLiteral("unnamed.bin");
    return safe;
}

QString MainWindow::formatFileSize(quint32 bytes)
{
    if (bytes < 1024) return QStringLiteral("%1 B").arg(bytes);
    if (bytes < 1024 * 1024) return QStringLiteral("%1 KB").arg(double(bytes) / 1024.0, 0, 'f', 1);
    if (bytes < 1024u * 1024u * 1024u) return QStringLiteral("%1 MB").arg(double(bytes) / (1024.0 * 1024.0), 0, 'f', 1);
    return QStringLiteral("%1 GB").arg(double(bytes) / (1024.0 * 1024.0 * 1024.0), 0, 'f', 2);
}

void MainWindow::setFileControlsEnabled(bool enabled)
{
    m_listButton->setEnabled(enabled && m_transferKind == TransferKind::None);
    m_uploadButton->setEnabled(enabled && m_transferKind == TransferKind::None);
    m_downloadButton->setEnabled(enabled && m_transferKind == TransferKind::None);
    m_deleteButton->setEnabled(enabled && m_transferKind == TransferKind::None);
    m_fileList->setEnabled(enabled);
}

void MainWindow::refreshSdList()
{
    if (!isBound() || m_transferKind != TransferKind::None) return;
    m_transferKind = TransferKind::Listing;
    m_listCursor = 0;
    m_fileList->clear();
    m_transferProgress->setRange(0, 0);
    setFileControlsEnabled(false);
    appendLog(QStringLiteral("开始分页扫描 FAT32 根目录……"));
    requestListEntry();
}

void MainWindow::requestListEntry()
{
    QByteArray packet;
    packet.append(char(FS_LIST_ENTRY));
    appendBe32(packet, m_listCursor);
    sendFsPacket(packet, WaitKind::ListEntry, QStringLiteral("读取目录项 %1").arg(m_listCursor));
}

void MainWindow::uploadFiles()
{
    if (!isBound() || m_transferKind != TransferKind::None) return;
    const QStringList paths = QFileDialog::getOpenFileNames(
        this, QStringLiteral("选择上传到 SD 卡的媒体文件"), QString(),
        QStringLiteral("媒体文件 (*.bmp *.BMP *.wav *.WAV SUBTITLE.BIN subtitle.bin);;所有文件 (*.*)"));
    if (paths.isEmpty()) return;
    m_uploadPaths = paths;
    m_queueIndex = 0;
    m_transferKind = TransferKind::Upload;
    m_transferDone = 0;
    m_transferTotal = 0;
    for (const QString &p : paths) {
        if (!isSupportedMediaName(p)) {
            QMessageBox::warning(this, QStringLiteral("不支持的文件类型"),
                QFileInfo(p).fileName() + QStringLiteral("：仅允许 BMP 图片、WAV 音频和 SUBTITLE.BIN 字幕资源。"));
            m_transferKind = TransferKind::None;
            m_uploadPaths.clear();
            setFileControlsEnabled(true);
            return;
        }
        const qint64 s = QFileInfo(p).size();
        if (s < 0 || quint64(s) > 0xffffffffULL) {
            QMessageBox::warning(this, QStringLiteral("文件过大"), QFileInfo(p).fileName() + QStringLiteral(" 超出 FAT32 单文件大小范围。"));
            m_transferKind = TransferKind::None;
            m_uploadPaths.clear();
            setFileControlsEnabled(true);
            return;
        }
        m_transferTotal += quint64(s);
    }
    m_transferProgress->setRange(0, 100);
    m_transferProgress->setValue(0);
    setFileControlsEnabled(false);
    m_statusPollTimer->stop();
    startNextUpload();
}

void MainWindow::startNextUpload()
{
    m_uploadFile.reset();
    if (m_queueIndex >= m_uploadPaths.size()) {
        finishTransfer(true, QStringLiteral("批量上传完成"));
        refreshSdList();
        return;
    }
    const QString path = m_uploadPaths.at(m_queueIndex);
    const QFileInfo info(path);
    m_currentName = info.fileName();
    bool valid = false;
    const QByteArray nameBytes = encodeFatName(m_currentName, &valid);
    if (!valid) { finishTransfer(false, QStringLiteral("不支持的 FAT32 文件名：%1").arg(m_currentName)); return; }
    m_uploadFile = std::make_unique<QFile>(path);
    if (!m_uploadFile->open(QIODevice::ReadOnly)) {
        finishTransfer(false, QStringLiteral("无法打开文件：%1").arg(path));
        return;
    }
    m_currentFileSize = quint32(info.size());
    m_currentOffset = 0;
    QByteArray packet;
    packet.append(char(FS_UPLOAD_BEGIN));
    appendBe16(packet, quint16(nameBytes.size() / 2));
    appendBe32(packet, m_currentFileSize);
    packet.append(nameBytes);
    sendFsPacket(packet, WaitKind::UploadBegin, QStringLiteral("上传准备：%1").arg(m_currentName));
}

void MainWindow::sendNextUploadChunk()
{
    if (!m_uploadFile) return;
    if (m_currentOffset >= m_currentFileSize) {
        QByteArray packet(1, char(FS_UPLOAD_END));
        sendFsPacket(packet, WaitKind::UploadEnd, QStringLiteral("提交文件：%1").arg(m_currentName));
        return;
    }
    const QByteArray chunk = m_uploadFile->read(FILE_CHUNK_SIZE);
    if (chunk.isEmpty() && !m_uploadFile->atEnd()) {
        finishTransfer(false, QStringLiteral("读取本地文件失败：%1").arg(m_currentName));
        return;
    }
    QByteArray packet;
    packet.append(char(FS_UPLOAD_DATA));
    appendBe32(packet, m_currentOffset);
    appendBe16(packet, quint16(chunk.size()));
    packet.append(chunk);
    sendFsPacket(packet, WaitKind::UploadData,
                 QStringLiteral("上传数据：%1，偏移 %2，长度 %3").arg(m_currentName).arg(m_currentOffset).arg(chunk.size()));
}

void MainWindow::downloadFiles()
{
    if (!isBound() || m_transferKind != TransferKind::None) return;
    const QList<QListWidgetItem *> selected = m_fileList->selectedItems();
    if (selected.isEmpty()) { QMessageBox::information(this, QStringLiteral("下载文件"), QStringLiteral("请先选择一个或多个文件。")); return; }
    const QString directory = QFileDialog::getExistingDirectory(this, QStringLiteral("选择下载保存目录"));
    if (directory.isEmpty()) return;
    m_downloadDirectory = directory;
    m_downloadNames.clear();
    m_transferTotal = 0;
    m_transferDone = 0;
    for (QListWidgetItem *item : selected) {
        m_downloadNames.append(item->data(ROLE_NAME).toString());
        m_transferTotal += item->data(ROLE_SIZE).toUInt();
    }
    m_queueIndex = 0;
    m_transferKind = TransferKind::Download;
    m_transferProgress->setRange(0, 100);
    m_transferProgress->setValue(0);
    setFileControlsEnabled(false);
    m_statusPollTimer->stop();
    startNextDownload();
}

void MainWindow::startNextDownload()
{
    m_downloadFile.reset();
    if (m_queueIndex >= m_downloadNames.size()) {
        finishTransfer(true, QStringLiteral("批量下载完成"));
        return;
    }
    m_currentName = m_downloadNames.at(m_queueIndex);
    QListWidgetItem *matched = nullptr;
    for (int i = 0; i < m_fileList->count(); ++i) {
        if (m_fileList->item(i)->data(ROLE_NAME).toString() == m_currentName) { matched = m_fileList->item(i); break; }
    }
    if (!matched) { finishTransfer(false, QStringLiteral("目录项已不存在：%1").arg(m_currentName)); return; }
    m_currentFileSize = matched->data(ROLE_SIZE).toUInt();
    m_currentOffset = 0;
    const QString localPath = QDir(m_downloadDirectory).filePath(localSafeName(m_currentName));
    m_downloadFile = std::make_unique<QSaveFile>(localPath);
    if (!m_downloadFile->open(QIODevice::WriteOnly)) {
        finishTransfer(false, QStringLiteral("无法创建本地文件：%1").arg(localPath));
        return;
    }
    if (m_currentFileSize == 0) {
        if (!m_downloadFile->commit()) { finishTransfer(false, QStringLiteral("保存空文件失败。")); return; }
        ++m_queueIndex;
        startNextDownload();
        return;
    }
    requestDownloadChunk();
}

void MainWindow::requestDownloadChunk()
{
    bool valid = false;
    const QByteArray nameBytes = encodeFatName(m_currentName, &valid);
    if (!valid) { finishTransfer(false, QStringLiteral("目录文件名无法编码：%1").arg(m_currentName)); return; }
    const quint16 want = quint16(qMin<quint32>(FILE_CHUNK_SIZE, m_currentFileSize - m_currentOffset));
    QByteArray packet;
    packet.append(char(FS_DOWNLOAD));
    appendBe16(packet, quint16(nameBytes.size() / 2));
    appendBe32(packet, m_currentOffset);
    appendBe16(packet, want);
    packet.append(nameBytes);
    sendFsPacket(packet, WaitKind::DownloadData,
                 QStringLiteral("下载数据：%1，偏移 %2").arg(m_currentName).arg(m_currentOffset));
}

void MainWindow::deleteFiles()
{
    if (!isBound() || m_transferKind != TransferKind::None) return;
    const QList<QListWidgetItem *> selected = m_fileList->selectedItems();
    if (selected.isEmpty()) { QMessageBox::information(this, QStringLiteral("删除文件"), QStringLiteral("请先选择一个或多个文件。")); return; }
    QStringList names;
    for (QListWidgetItem *item : selected) names.append(item->data(ROLE_NAME).toString());
    if (QMessageBox::question(this, QStringLiteral("确认删除"),
        QStringLiteral("确定从 SD 卡根目录删除选中的 %1 个文件吗？此操作不可撤销。").arg(names.size())) != QMessageBox::Yes) return;
    m_deleteNames = names;
    m_queueIndex = 0;
    m_transferKind = TransferKind::Delete;
    m_transferTotal = quint64(names.size());
    m_transferDone = 0;
    m_transferProgress->setRange(0, 100);
    m_transferProgress->setValue(0);
    setFileControlsEnabled(false);
    m_statusPollTimer->stop();
    sendDeleteCurrent();
}

void MainWindow::sendDeleteCurrent()
{
    if (m_queueIndex >= m_deleteNames.size()) {
        finishTransfer(true, QStringLiteral("批量删除完成"));
        refreshSdList();
        return;
    }
    m_currentName = m_deleteNames.at(m_queueIndex);
    bool valid = false;
    const QByteArray nameBytes = encodeFatName(m_currentName, &valid);
    if (!valid) { finishTransfer(false, QStringLiteral("非法文件名：%1").arg(m_currentName)); return; }
    QByteArray packet;
    packet.append(char(FS_DELETE));
    appendBe16(packet, quint16(nameBytes.size() / 2));
    packet.append(nameBytes);
    sendFsPacket(packet, WaitKind::DeleteEntry, QStringLiteral("删除：%1").arg(m_currentName));
}

void MainWindow::handleFileResponse(const QByteArray &data)
{
    if (data.isEmpty()) return;
    const quint8 command = quint8(data[0]);
    m_responseTimer->stop();
    m_waitingResponse = false;
    setNetworkState(QStringLiteral("FPGA 通信正常"));

    if (command == FS_LIST_REPLY && m_transferKind == TransferKind::Listing && m_waitKind == WaitKind::ListEntry) {
        if (data.size() < 14) { finishTransfer(false, QStringLiteral("目录响应长度错误。")); return; }
        const quint8 status = quint8(data[1]);
        if (status != 0) { finishTransfer(false, QStringLiteral("读取目录失败，错误码 %1。").arg(status)); return; }
        const quint8 hasEntry = quint8(data[6]);
        if (!hasEntry) {
            const int count = m_fileList->count();
            finishTransfer(true, QStringLiteral("根目录读取完成，共 %1 个文件。").arg(count));
            return;
        }
        const quint16 nameUnits = readBe16(data, 7);
        const quint32 fileSize = readBe32(data, 9);
        const quint8 attr = quint8(data[13]);
        if (nameUnits == 0 || nameUnits > 255 || data.size() != 14 + int(nameUnits) * 2) {
            finishTransfer(false, QStringLiteral("目录文件名字段长度错误。")); return;
        }
        const QString name = decodeFatName(data.mid(14));
        if (isSupportedMediaName(name)) {
            auto *item = new QListWidgetItem(QStringLiteral("%1    %2").arg(name, formatFileSize(fileSize)));
            item->setData(ROLE_NAME, name);
            item->setData(ROLE_SIZE, fileSize);
            item->setData(ROLE_ATTR, attr);
            m_fileList->addItem(item);
        }
        ++m_listCursor;
        setTransferProgress(m_listCursor, 0);
        requestListEntry();
        return;
    }

    if (command == FS_BEGIN_REPLY && m_transferKind == TransferKind::Upload && m_waitKind == WaitKind::UploadBegin) {
        if (data.size() < 2 || quint8(data[1]) != 0) {
            finishTransfer(false, QStringLiteral("上传初始化失败，错误码 %1。请检查重名、空间及根目录容量。")
                           .arg(data.size() > 1 ? quint8(data[1]) : 255)); return;
        }
        sendNextUploadChunk();
        return;
    }

    if (command == FS_DATA_REPLY && m_transferKind == TransferKind::Upload && m_waitKind == WaitKind::UploadData) {
        if (data.size() < 6 || quint8(data[1]) != 0) {
            finishTransfer(false, QStringLiteral("上传数据块失败，错误码 %1。")
                           .arg(data.size() > 1 ? quint8(data[1]) : 255)); return;
        }
        const quint32 ackOffset = readBe32(data, 2);
        if (ackOffset != m_currentOffset + quint32(m_lastPacket.size() - 7)) {
            finishTransfer(false, QStringLiteral("FPGA 上传偏移确认不一致。")); return;
        }
        const quint32 sentBytes = quint32(m_lastPacket.size() - 7);
        m_currentOffset = ackOffset;
        m_transferDone += sentBytes;
        setTransferProgress(qint64(m_transferDone), qint64(m_transferTotal));
        sendNextUploadChunk();
        return;
    }

    if (command == FS_END_REPLY && m_transferKind == TransferKind::Upload && m_waitKind == WaitKind::UploadEnd) {
        if (data.size() < 2 || quint8(data[1]) != 0) {
            finishTransfer(false, QStringLiteral("文件目录项提交失败，错误码 %1。")
                           .arg(data.size() > 1 ? quint8(data[1]) : 255)); return;
        }
        appendLog(QStringLiteral("上传完成：%1").arg(m_currentName));
        ++m_queueIndex;
        startNextUpload();
        return;
    }

    if (command == FS_DOWN_REPLY && m_transferKind == TransferKind::Download && m_waitKind == WaitKind::DownloadData) {
        if (data.size() < 8 || quint8(data[1]) != 0) {
            finishTransfer(false, QStringLiteral("下载数据失败，错误码 %1。")
                           .arg(data.size() > 1 ? quint8(data[1]) : 255)); return;
        }
        const quint32 offset = readBe32(data, 2);
        const quint16 count = readBe16(data, 6);
        if (offset != m_currentOffset || count > FILE_CHUNK_SIZE || data.size() != 8 + count ||
            quint64(m_currentOffset) + count > m_currentFileSize) {
            finishTransfer(false, QStringLiteral("下载数据包偏移或长度不匹配。")); return;
        }
        if (count && m_downloadFile->write(data.constData() + 8, count) != count) {
            finishTransfer(false, QStringLiteral("写入本地文件失败。")); return;
        }
        m_currentOffset += count;
        m_transferDone += count;
        setTransferProgress(qint64(m_transferDone), qint64(m_transferTotal));
        if (m_currentOffset >= m_currentFileSize) {
            if (!m_downloadFile->commit()) { finishTransfer(false, QStringLiteral("保存下载文件失败：%1").arg(m_downloadFile->errorString())); return; }
            appendLog(QStringLiteral("下载完成：%1").arg(m_currentName));
            ++m_queueIndex;
            startNextDownload();
        } else if (count == 0) finishTransfer(false, QStringLiteral("FPGA 返回空数据块，下载中止。"));
        else requestDownloadChunk();
        return;
    }

    if (command == FS_DELETE_REPLY && m_transferKind == TransferKind::Delete && m_waitKind == WaitKind::DeleteEntry) {
        if (data.size() < 2 || quint8(data[1]) != 0) {
            finishTransfer(false, QStringLiteral("删除失败：%1，错误码 %2。")
                           .arg(m_currentName).arg(data.size() > 1 ? quint8(data[1]) : 255)); return;
        }
        appendLog(QStringLiteral("已删除：%1").arg(m_currentName));
        ++m_queueIndex;
        m_transferDone = quint64(m_queueIndex);
        setTransferProgress(qint64(m_transferDone), qint64(m_transferTotal));
        sendDeleteCurrent();
        return;
    }
    appendLog(QStringLiteral("收到的文件管理响应与当前操作不匹配。"));
}

void MainWindow::setTransferProgress(qint64 done, qint64 total)
{
    if (total <= 0) { m_transferProgress->setValue(0); return; }
    const qint64 rawPercent = (done * qint64(100)) / total;
    const int percent = int(qBound<qint64>(qint64(0), rawPercent, qint64(100)));
    m_transferProgress->setValue(percent);
}

void MainWindow::finishTransfer(bool success, const QString &message)
{
    m_responseTimer->stop();
    m_waitingResponse = false;
    m_waitKind = WaitKind::None;
    clearTransferResources();
    appendLog(message);
    if (success) m_transferProgress->setValue(100);
    else QMessageBox::warning(this, QStringLiteral("SD 卡文件管理"), message);
    m_transferKind = TransferKind::None;
    m_uploadPaths.clear();
    m_downloadNames.clear();
    m_deleteNames.clear();
    setFileControlsEnabled(isBound());
    if (m_autoPollCheck->isChecked()) m_statusPollTimer->start();
}

void MainWindow::clearTransferResources()
{
    if (m_uploadFile && m_uploadFile->isOpen()) m_uploadFile->close();
    m_uploadFile.reset();
    if (m_downloadFile && m_downloadFile->isOpen()) m_downloadFile->cancelWriting();
    m_downloadFile.reset();
}

void MainWindow::onResponseTimeout()
{
    if (!m_waitingResponse) return;
    m_waitingResponse = false;
    if (m_waitKind != WaitKind::Status) {
        finishTransfer(false, QStringLiteral("文件管理命令响应超时：%1。请检查 FPGA 文件服务、SD 卡状态及 UDP 链路。")
                       .arg(m_lastCommand));
    } else {
        m_waitKind = WaitKind::None;
        setNetworkState(QStringLiteral("UDP 已绑定，但 FPGA 未响应"), true);
        appendLog(QStringLiteral("命令响应超时：%1。检查 ARP、UDP 目的端口及板端状态。").arg(m_lastCommand));
    }
}
void MainWindow::onStatusPollTimeout() { if (isBound() && !m_waitingResponse && m_transferKind == TransferKind::None) readStatus(); }

void MainWindow::runDiagnostic(const QString &program, const QStringList &args, const QString &description)
{
    auto *process = new QProcess(this);
    process->setProcessChannelMode(QProcess::SeparateChannels);
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process]() {
        const QByteArray b = process->readAllStandardOutput();
        if (!b.isEmpty()) appendLog(QString::fromLocal8Bit(b).trimmed());
    });
    connect(process, &QProcess::readyReadStandardError, this, [this, process]() {
        const QByteArray b = process->readAllStandardError();
        if (!b.isEmpty()) appendLog(QString::fromLocal8Bit(b).trimmed());
    });
    connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, process, description](int code, QProcess::ExitStatus status) {
        appendLog(QStringLiteral("%1：exitCode=%2，%3").arg(description).arg(code)
                  .arg(status == QProcess::NormalExit ? QStringLiteral("NormalExit") : QStringLiteral("CrashExit")));
        process->deleteLater();
    });
    appendLog(description + QStringLiteral("：开始执行"));
    process->start(program, args);
}
void MainWindow::pingFpga()
{
    // Lite V2 verifies the path with the same UDP application protocol used
    // by the control panel. ICMP Echo is intentionally not part of this
    // compact MAC/IP implementation.
    if (!isBound()) {
        appendLog(QStringLiteral("请先绑定本机 UDP 端口，再执行 UDP 探测。"));
        return;
    }
    sendCommand(CMD_READ_STATUS, 0, QStringLiteral("UDP 网络探测 / 读取 FPGA 状态"));
}
void MainWindow::showArpTable()
{
    QHostAddress boardIp, localIp; quint16 bp = 0, lp = 0;
    if (!validateNetwork(boardIp, localIp, bp, lp)) return;
    runDiagnostic(QStringLiteral("arp"), {QStringLiteral("-a"), boardIp.toString()}, QStringLiteral("查看 ARP 表"));
}
void MainWindow::clearLog() { m_log->clear(); }
void MainWindow::appendLog(const QString &message)
{
    m_log->appendPlainText(QStringLiteral("[%1] %2")
        .arg(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss")), message));
}
void MainWindow::setNetworkState(const QString &message, bool error)
{
    m_networkState->setText(message);
    m_networkState->setStyleSheet(error
        ? QStringLiteral("QLabel { color: #c62828; font-weight: bold; }")
        : QStringLiteral("QLabel { color: #16803c; font-weight: bold; }"));
}
