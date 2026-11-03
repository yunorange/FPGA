#include "protocol.h"

namespace Proto {

quint16 crc16(const QByteArray &data)
{
    quint16 crc = 0xFFFF;
    for (unsigned char c : data) {
        crc ^= c;
        for (int i = 0; i < 8; ++i)
            crc = (crc & 1) ? quint16((crc >> 1) ^ 0xA001) : quint16(crc >> 1);
    }
    return crc;
}

quint32 crc32(const QByteArray &data)
{
    quint32 crc = 0xFFFFFFFFu;
    for (unsigned char c : data) {
        crc ^= quint32(c);
        for (int i = 0; i < 8; ++i)
            crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
    }
    return crc ^ 0xFFFFFFFFu;
}

QByteArray encode(quint8 cmd, quint16 seq, const QByteArray &payload)
{
    if (payload.size() > MaxPayload)
        return {};

    QByteArray packet("QHMU", 4);
    packet.append(char(Version));
    packet.append(char(cmd));
    packet.append(char((seq >> 8) & 0xFF));
    packet.append(char(seq & 0xFF));
    packet.append(char((payload.size() >> 8) & 0xFF));
    packet.append(char(payload.size() & 0xFF));
    packet.append(payload);

    const quint16 crc = crc16(packet);
    packet.append(char(crc & 0xFF));       // CRC low byte first
    packet.append(char((crc >> 8) & 0xFF));
    return packet;
}

bool decode(const QByteArray &packet, Packet &out, QString *error)
{
    const auto fail = [error](const QString &message) {
        if (error)
            *error = message;
        return false;
    };

    if (packet.size() < HeaderSize + TrailerSize)
        return fail(QStringLiteral("协议包长度不足"));
    if (packet.left(4) != QByteArray("QHMU", 4))
        return fail(QStringLiteral("协议头不是 QHMU"));
    if (quint8(packet.at(4)) != Version)
        return fail(QStringLiteral("协议版本不匹配"));

    const int payloadLength =
        (int(quint8(packet.at(8))) << 8) | int(quint8(packet.at(9)));

    if (payloadLength > MaxPayload)
        return fail(QStringLiteral("payload 超过最大长度"));
    if (packet.size() != HeaderSize + payloadLength + TrailerSize)
        return fail(QStringLiteral("数据包长度与 payload 长度不一致"));

    const quint16 receivedCrc =
        quint16(quint8(packet.at(packet.size() - 2))) |
        (quint16(quint8(packet.at(packet.size() - 1))) << 8);

    if (crc16(packet.left(packet.size() - TrailerSize)) != receivedCrc)
        return fail(QStringLiteral("CRC16 校验失败"));

    out.cmd = quint8(packet.at(5));
    out.seq = (quint16(quint8(packet.at(6))) << 8) |
              quint16(quint8(packet.at(7)));
    out.payload = packet.mid(HeaderSize, payloadLength);
    return true;
}

void appendU16(QByteArray &out, quint16 value)
{
    out.append(char((value >> 8) & 0xFF));
    out.append(char(value & 0xFF));
}

void appendU32(QByteArray &out, quint32 value)
{
    out.append(char((value >> 24) & 0xFF));
    out.append(char((value >> 16) & 0xFF));
    out.append(char((value >> 8) & 0xFF));
    out.append(char(value & 0xFF));
}

quint16 readU16(const QByteArray &data, int offset)
{
    if (offset < 0 || offset + 2 > data.size())
        return 0;
    return (quint16(quint8(data.at(offset))) << 8) |
           quint16(quint8(data.at(offset + 1)));
}

quint32 readU32(const QByteArray &data, int offset)
{
    if (offset < 0 || offset + 4 > data.size())
        return 0;
    return (quint32(quint8(data.at(offset))) << 24) |
           (quint32(quint8(data.at(offset + 1))) << 16) |
           (quint32(quint8(data.at(offset + 2))) << 8) |
           quint32(quint8(data.at(offset + 3)));
}

} // namespace Proto
