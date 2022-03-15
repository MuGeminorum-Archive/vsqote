#include "qtest.h"

qtest::qtest(QWidget* parent)
    : QMainWindow(parent)
    , ui(new Ui_qtest)
{
    ui->setupUi(this);
}

qtest::~qtest()
{
    delete ui; 
}