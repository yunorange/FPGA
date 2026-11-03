#include "mainwindow.h"
#include <QApplication>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("QHMU FPGA HDMI Control"));
    QApplication::setOrganizationName(QStringLiteral("QHMU"));
    MainWindow window;
    window.show();
    return app.exec();
}
