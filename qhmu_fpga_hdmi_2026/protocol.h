#pragma once

#include <QByteArray>
#include <QString>
#include <QtGlobal>

namespace Proto {

constexpr quint8 Version = 1;
constexpr int MaxPayload = 720;
constexpr int HeaderSize = 10;
constexpr int TrailerSize = 2;
constexpr int MaxDatagram = HeaderSize + MaxPayload + TrailerSize;

enum Command : quint8 {
    GetStatus       = 0x01,
    SetParam        = 0x10,
    Prev            = 0x11,
    Next            = 0x12,
    AutoToggle      = 0x13,

    FileList        = 0x20,
    FileUploadBegin = 0x21,
    FileUploadChunk = 0x22,
    FileUploadEnd   = 0x23,
    FileDownload    = 0x24,
    FileDelete      = 0x25,

    // FPGA -> PC asynchronous download stream events.
    DownloadChunk   = 0x34,
    DownloadEnd     = 0x35
};

enum Param : quint8 {
    Brightness = 0x01,
    Contrast   = 0x02,
    Transition = 0x03
};

struct Packet {
    quint8 cmd = 0;
    quint16 seq = 0;
    QByteArray payload;
};

quint16 crc16(const QByteArray &data);
quint32 crc32(const QByteArray &data);
QByteArray encode(quint8 cmd, quint16 seq, const QByteArray &payload);
bool decode(const QByteArray &data, Packet &out, QString *error = nullptr);

void appendU16(QByteArray &out, quint16 value);
void appendU32(QByteArray &out, quint32 value);
quint16 readU16(const QByteArray &data, int offset);
quint32 readU32(const QByteArray &data, int offset);

} // namespace Proto
