#pragma once
#include "ui_qtest.h"
#include <QMainWindow>

class qtest : public QMainWindow {
    Q_OBJECT
    
public:
    qtest(QWidget* parent = nullptr);
    ~qtest();

private:
    Ui_qtest* ui;
};