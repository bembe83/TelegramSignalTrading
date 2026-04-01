//+------------------------------------------------------------------+
//|                    Order Manager from JSON Files                 |
//|                        MetaTrader 4 Expert Advisor               |
//+------------------------------------------------------------------+
#property copyright "Bembe83"
#property link      ""
#property version   "1.00"
#property strict

// Input parameters
input string InputFolder = "input";           // Folder for input JSON files
input string ArchiveInputFolder = "archive\\input";  // Folder to move processed input files
input string OutputFolder = "output";         // Folder for output ticket files
input string ArchiveOutputFolder = "archive\\output"; // Folder to archive processed output files
input int CheckInterval = 5000;               // Check interval in milliseconds

// Global variables
int lastCheckTime = 0;
string LogFilePath = "orders_errors.log";

// Structure for order data
struct OrderData {
    string action;
    string msg_id;
    int ticket;
    string symbol;
    int type;
    double volume;
    double price;
    double sl;
    double tp;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    int timerSeconds = MathMax(1, CheckInterval / 1000);

    Print("[OnInit] Expert Advisor initialized");
    Print("[OnInit] Check interval: ", CheckInterval, "ms");
    Print("[OnInit] Input folder: ", InputFolder);
    Print("[OnInit] Archive input folder: ", ArchiveInputFolder);
    Print("[OnInit] Output folder: ", OutputFolder);
    Print("[OnInit] Archive output folder: ", ArchiveOutputFolder);
    
    EventSetTimer(timerSeconds);
    Print("[OnInit] Timer set to ", timerSeconds, " seconds");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // This EA doesn't need to do anything on tick, timer handles it
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    ProcessFiles();
    // ArchiveOutputFiles(); // Disabled - keep output files in output folder for external system to read
}

//+------------------------------------------------------------------+
//| Process JSON files in input folder                               |
//+------------------------------------------------------------------+
void ProcessFiles() {
    string inputPath = InputFolder + "\\";
    string archiveInputPath = ArchiveInputFolder + "\\";
    
    Print("[ProcessFiles] Checking folder: ", inputPath);
    
    // Find JSON files
    string fileName;
    long handle = FileFindFirst(inputPath + "*.json", fileName);
    
    if (handle == INVALID_HANDLE) {
        Print("[ProcessFiles] No JSON files found in ", inputPath);
        return;
    }
    
    Print("[ProcessFiles] Found files, processing...");
    
    do {
        Print("[ProcessFiles] Processing file: ", fileName);
        string fullPath = inputPath + fileName;
        if (FileIsExist(fullPath)) {
            OrderData order;
            if (ParseJSONFile(fullPath, order)) {
                Print("[ProcessFiles] Successfully parsed JSON, action: ", order.action);
                ProcessOrder(order);
            } else {
                Print("[ProcessFiles] Failed to parse JSON: ", fileName);
            }
            // Move file to archive input
            if (!MoveFile(fullPath, archiveInputPath + fileName)) {
                Print("[ProcessFiles] Warning: Failed to move file to archive: ", fileName);
            }
        } else {
            Print("[ProcessFiles] File does not exist: ", fullPath);
        }
    } while (FileFindNext(handle, fileName));
    FileFindClose(handle);
    Print("[ProcessFiles] Finished processing files");
}

//+------------------------------------------------------------------+
//| Parse JSON file and extract order data                           |
//+------------------------------------------------------------------+
bool ParseJSONFile(string filePath, OrderData &order) {
    int handle = FileOpen(filePath, FILE_READ | FILE_TXT | FILE_ANSI);
    if (handle == INVALID_HANDLE) {
        Print("[ParseJSONFile] Error opening file: ", filePath, " | Error: ", GetLastError());
        return false;
    }
    
    string json = "";
    while (!FileIsEnding(handle)) {
        json += FileReadString(handle);
    }
    FileClose(handle);
    
    StringTrimLeft(json);
    StringTrimRight(json);
    
    order.action = ToUpper(ExtractStringValue(json, "action"));
    if (order.action == "") {
        Print("[ParseJSONFile] Missing field 'action'");
        return false;
    }
    
    order.msg_id = ExtractStringValue(json, "msg_id");
    if (order.msg_id == "") {
        Print("[ParseJSONFile] Missing field 'msg_id'");
        return false;
    }
    
    if (order.action == "CREATE") {
        order.symbol = ExtractStringValue(json, "symbol");
        string typeStr = ToUpper(ExtractStringValue(json, "type"));
        string sideStr = ToUpper(ExtractStringValue(json, "side"));

        if (typeStr == "MARKET") {
            if (sideStr == "BUY") order.type = OP_BUY;
            else if (sideStr == "SELL") order.type = OP_SELL;
            else {
                Print("[ParseJSONFile] Invalid MARKET side: '", sideStr, "'");
                return false;
            }
        } else if (typeStr == "BUY") order.type = OP_BUY;
        else if (typeStr == "SELL") order.type = OP_SELL;
        else if (typeStr == "BUYLIMIT") order.type = OP_BUYLIMIT;
        else if (typeStr == "SELLLIMIT") order.type = OP_SELLLIMIT;
        else if (typeStr == "BUYSTOP") order.type = OP_BUYSTOP;
        else if (typeStr == "SELLSTOP") order.type = OP_SELLSTOP;
        else {
            Print("[ParseJSONFile] Invalid order type: '", typeStr, "'");
            return false;
        }
        
        order.volume = ExtractDoubleValue(json, "volume");
        if (order.type == OP_BUY)
            order.price = MarketInfo(order.symbol, MODE_ASK);
        else if (order.type == OP_SELL)
            order.price = MarketInfo(order.symbol, MODE_BID);
        else
            order.price = ExtractDoubleValue(json, "price");
        order.sl = ExtractDoubleValue(json, "sl");
        order.tp = ExtractDoubleValue(json, "tp");
    } else if (order.action == "UPDATE" || order.action == "CANCEL" || order.action == "CLOSE") {
        order.ticket = ExtractIntValue(json, "ticket");
        if (order.ticket <= 0) {
            Print("[ParseJSONFile] Missing/invalid 'ticket' for action: ", order.action);
            return false;
        }

        if (order.action == "UPDATE") {
            order.price = ExtractDoubleValue(json, "price");
            order.sl = ExtractDoubleValue(json, "sl");
            order.tp = ExtractDoubleValue(json, "tp");
        }
    } else {
        Print("[ParseJSONFile] Unsupported action: ", order.action);
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Extract string value from JSON                                   |
//+------------------------------------------------------------------+
int SkipWhitespace(string text, int pos) {
    int len = StringLen(text);
    while (pos < len) {
        int c = StringGetCharacter(text, pos);
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
        pos++;
    }
    return pos;
}

bool FindJsonValueStart(string json, string key, int &valueStart) {
    string token = "\"" + key + "\"";
    int keyPos = StringFind(json, token);
    if (keyPos == -1) return false;

    int pos = keyPos + StringLen(token);
    pos = SkipWhitespace(json, pos);

    if (pos >= StringLen(json) || StringGetCharacter(json, pos) != ':') return false;
    pos++;
    pos = SkipWhitespace(json, pos);

    if (pos >= StringLen(json)) return false;
    valueStart = pos;
    return true;
}

string ExtractStringValue(string json, string key) {
    int start = 0;
    if (!FindJsonValueStart(json, key, start)) return "";
    if (StringGetCharacter(json, start) != '"') return "";

    start++;
    int end = start;
    while (end < StringLen(json)) {
        int c = StringGetCharacter(json, end);
        if (c == '"' && StringGetCharacter(json, end - 1) != '\\') break;
        end++;
    }
    if (end >= StringLen(json)) return "";

    return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Extract double value from JSON                                   |
//+------------------------------------------------------------------+
double ExtractDoubleValue(string json, string key) {
    int start = 0;
    if (!FindJsonValueStart(json, key, start)) {
        Print("[ExtractDoubleValue] Key not found: ", key);
        return 0.0;
    }

    int end = start;

    if (StringGetCharacter(json, start) == '"') {
        start++;
        end = StringFind(json, "\"", start);
        if (end == -1) {
            Print("[ExtractDoubleValue] Closing quote not found for: ", key);
            return 0.0;
        }

        string value = StringSubstr(json, start, end - start);
        double result = StrToDouble(value);
        Print("[ExtractDoubleValue] Key: ", key, " Value (quoted): ", value, " Result: ", result);
        return result;
    }

    while (end < StringLen(json) &&
           (StringGetCharacter(json, end) == '.' ||
            StringGetCharacter(json, end) == '-' ||
            (StringGetCharacter(json, end) >= '0' && StringGetCharacter(json, end) <= '9'))) {
        end++;
    }

    string value = StringSubstr(json, start, end - start);
    double result = StrToDouble(value);
    Print("[ExtractDoubleValue] Key: ", key, " Value (numeric): ", value, " Result: ", result);
    return result;
}

//+------------------------------------------------------------------+
//| Extract int value from JSON                                      |
//+------------------------------------------------------------------+
int ExtractIntValue(string json, string key) {
    int start = 0;
    if (!FindJsonValueStart(json, key, start)) return 0;

    int end = start;
    if (StringGetCharacter(json, end) == '-') end++;
    while (end < StringLen(json) && (StringGetCharacter(json, end) >= '0' && StringGetCharacter(json, end) <= '9')) {
        end++;
    }
    string value = StringSubstr(json, start, end - start);
    return StrToInteger(value);
}

//+------------------------------------------------------------------+
//| Convert string to uppercase                                      |
//+------------------------------------------------------------------+
string ToUpper(string s) {
    string result = "";
    for (int i = 0; i < StringLen(s); i++) {
        int c = StringGetCharacter(s, i);
        if (c >= 'a' && c <= 'z') c -= 32;
        result += CharToString((uchar)c);
    }
    return result;
}

double NormalizePrice(string symbol, double price) {
    int digits = (int)MarketInfo(symbol, MODE_DIGITS);
    return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
//| Log errors to file                                               |
//+------------------------------------------------------------------+
void LogError(string action, string msg_id, string errorMsg, int errorCode) {
    string logPath = LogFilePath;
    datetime now = TimeCurrent();
    string timestamp = TimeToString(now, TIME_DATE) + " " + TimeToString(now, TIME_SECONDS);
    
    int handle = FileOpen(logPath, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
    if (handle == INVALID_HANDLE) {
        handle = FileOpen(logPath, FILE_WRITE | FILE_TXT | FILE_ANSI);
        if (handle == INVALID_HANDLE) {
            Print("[LogError] CRITICAL - Cannot create log file: ", logPath, " | Error: ", GetLastError());
            return;
        }
    } else {
        FileSeek(handle, 0, SEEK_END);
    }
    
    string logEntry = timestamp + " | ACTION: " + action + " | MSG_ID: " + msg_id + " | ERROR: " + errorMsg + " | CODE: " + IntegerToString(errorCode);
    FileWriteString(handle, logEntry + "\n");
    FileClose(handle);
    Print("[LogError] Logged error to file: ", logPath);
}

//+------------------------------------------------------------------+
//| Process the order based on action                                |
//+------------------------------------------------------------------+
void ProcessOrder(OrderData &order) {
    if (order.action == "CREATE") {
        CreateOrder(order);
    } else if (order.action == "UPDATE") {
        UpdateOrder(order);
    } else if (order.action == "CANCEL") {
        CancelOrder(order);
    } else if (order.action == "CLOSE") {
        CloseOrder(order);
    }
}

//+------------------------------------------------------------------+
//| Create a new order                                               |
//+------------------------------------------------------------------+
void CreateOrder(OrderData &order) {
    Print("[CreateOrder] DEBUG - Symbol: ", order.symbol, " | Type: ", order.type);
    Print("[CreateOrder] DEBUG - Volume: ", order.volume, " | Price: ", order.price);
    Print("[CreateOrder] DEBUG - SL: ", order.sl, " | TP: ", order.tp);

    if (!SymbolSelect(order.symbol, true)) {
        Print("[CreateOrder] ERROR - Failed to select symbol: ", order.symbol);
        LogError("CREATE", order.msg_id, "Failed to select symbol: " + order.symbol, GetLastError());
        return;
    }

    double requestPrice = order.price;
    if (order.type == OP_BUY) requestPrice = MarketInfo(order.symbol, MODE_ASK);
    else if (order.type == OP_SELL) requestPrice = MarketInfo(order.symbol, MODE_BID);

    double normalizedPrice = NormalizePrice(order.symbol, requestPrice);
    double normalizedSl = order.sl > 0.0 ? NormalizePrice(order.symbol, order.sl) : 0.0;
    double normalizedTp = order.tp > 0.0 ? NormalizePrice(order.symbol, order.tp) : 0.0;
    
    int ticket = OrderSend(order.symbol, order.type, order.volume, normalizedPrice, 3, normalizedSl, normalizedTp, "JSON Order", 0, 0, clrBlue);
    if (ticket < 0) {
        int errorCode = GetLastError();
        Print("[CreateOrder] ERROR - OrderSend failed with error code: ", errorCode);
        LogError("CREATE", order.msg_id, "OrderSend failed", errorCode);
    } else {
        Print("[CreateOrder] SUCCESS - Order created with ticket: ", ticket);
        // Write output file with msg_id and ticket
        WriteOutputFile(order.msg_id, ticket);
    }
}

bool UpdateOpenOrderSLTP(OrderData &order) {
    if (!OrderSelect(order.ticket, SELECT_BY_TICKET)) {
        LogError("UPDATE", order.msg_id, "Failed to select ticket: " + IntegerToString(order.ticket), GetLastError());
        return false;
    }

    int type = OrderType();
    if (type > OP_SELL) {
        LogError("UPDATE", order.msg_id, "Selected order is not an open position, ticket: " + IntegerToString(order.ticket), 0);
        return false;
    }

    string symbol = OrderSymbol();
    double price = OrderOpenPrice();
    double sl = order.sl > 0.0 ? NormalizePrice(symbol, order.sl) : 0.0;
    double tp = order.tp > 0.0 ? NormalizePrice(symbol, order.tp) : 0.0;

    if (!OrderModify(order.ticket, NormalizePrice(symbol, price), sl, tp, 0, clrGreen)) {
        int errorCode = GetLastError();
        LogError("UPDATE", order.msg_id, "OrderModify failed for open position, ticket: " + IntegerToString(order.ticket), errorCode);
        return false;
    }
    return true;
}

bool UpdatePendingOrder(OrderData &order) {
    if (!OrderSelect(order.ticket, SELECT_BY_TICKET)) {
        LogError("UPDATE", order.msg_id, "Failed to select ticket: " + IntegerToString(order.ticket), GetLastError());
        return false;
    }

    int type = OrderType();
    if (type <= OP_SELL) {
        LogError("UPDATE", order.msg_id, "Selected order is not a pending order, ticket: " + IntegerToString(order.ticket), 0);
        return false;
    }

    string symbol = OrderSymbol();
    double currentPrice = OrderOpenPrice();
    double newPrice = order.price > 0.0 ? order.price : currentPrice;
    double sl = order.sl > 0.0 ? NormalizePrice(symbol, order.sl) : 0.0;
    double tp = order.tp > 0.0 ? NormalizePrice(symbol, order.tp) : 0.0;

    if (!OrderModify(order.ticket, NormalizePrice(symbol, newPrice), sl, tp, OrderExpiration(), clrGreen)) {
        int errorCode = GetLastError();
        LogError("UPDATE", order.msg_id, "OrderModify failed for pending order, ticket: " + IntegerToString(order.ticket), errorCode);
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Update an existing order                                         |
//+------------------------------------------------------------------+
void UpdateOrder(OrderData &order) {
    Print("[UpdateOrder] DEBUG - Ticket: ", order.ticket, " | Price: ", order.price, " | SL: ", order.sl, " | TP: ", order.tp);

    if (!OrderSelect(order.ticket, SELECT_BY_TICKET)) {
        Print("[UpdateOrder] ERROR - Ticket not found: ", order.ticket);
        return;
    }

    if (OrderType() <= OP_SELL) {
        if (UpdateOpenOrderSLTP(order)) {
            Print("[UpdateOrder] SUCCESS - Position updated: ", order.ticket);
        } else {
            Print("[UpdateOrder] ERROR - Failed to update position: ", order.ticket, " | Error: ", GetLastError());
        }
        return;
    }

    if (UpdatePendingOrder(order)) {
        Print("[UpdateOrder] SUCCESS - Pending order updated: ", order.ticket);
    } else {
        Print("[UpdateOrder] ERROR - Failed to update pending order: ", order.ticket, " | Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Cancel (close/delete) an existing order                          |
//+------------------------------------------------------------------+
void CancelOrder(OrderData &order) {
    Print("[CancelOrder] DEBUG - Ticket: ", order.ticket);
    if (OrderSelect(order.ticket, SELECT_BY_TICKET)) {
        bool result;
        if (OrderType() <= OP_SELL) {
            // Open order, close it
            Print("[CancelOrder] Closing open order");
            result = OrderClose(order.ticket, OrderLots(), OrderClosePrice(), 3, clrRed);
            if (!result) {
                int errorCode = GetLastError();
                Print("[CancelOrder] ERROR - OrderClose failed with error: ", errorCode);
                LogError("CANCEL", order.msg_id, "OrderClose failed, ticket: " + IntegerToString(order.ticket), errorCode);
            } else {
                Print("[CancelOrder] SUCCESS - Order cancelled: ", order.ticket);
            }
        } else {
            // Pending order, delete it
            Print("[CancelOrder] Deleting pending order");
            result = OrderDelete(order.ticket);
            if (!result) {
                int errorCode = GetLastError();
                Print("[CancelOrder] ERROR - OrderDelete failed with error: ", errorCode);
                LogError("CANCEL", order.msg_id, "OrderDelete failed, ticket: " + IntegerToString(order.ticket), errorCode);
            } else {
                Print("[CancelOrder] SUCCESS - Order cancelled: ", order.ticket);
            }
        }
    } else {
        Print("[CancelOrder] ERROR - Order not found: ", order.ticket);
        LogError("CANCEL", order.msg_id, "Order not found, ticket: " + IntegerToString(order.ticket), GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Close an open position                                           |
//+------------------------------------------------------------------+
void CloseOrder(OrderData &order) {
    Print("[CloseOrder] DEBUG - Ticket: ", order.ticket);
    if (OrderSelect(order.ticket, SELECT_BY_TICKET)) {
        if (OrderType() <= OP_SELL) {
            // This is an open position, close it
            bool result = OrderClose(order.ticket, OrderLots(), OrderClosePrice(), 3, clrOrange);
            if (!result) {
                int errorCode = GetLastError();
                Print("[CloseOrder] ERROR - OrderClose failed with error: ", errorCode);
                LogError("CLOSE", order.msg_id, "OrderClose failed, ticket: " + IntegerToString(order.ticket), errorCode);
            } else {
                Print("[CloseOrder] SUCCESS - Order closed: ", order.ticket);
            }
        } else {
            // This is a pending order, not an open position
            Print("[CloseOrder] ERROR - Cannot close pending order, use CANCEL instead: ", order.ticket);
            LogError("CLOSE", order.msg_id, "Cannot close pending order, use CANCEL instead. Ticket: " + IntegerToString(order.ticket), 0);
        }
    } else {
        Print("[CloseOrder] ERROR - Order not found: ", order.ticket);
        LogError("CLOSE", order.msg_id, "Order not found, ticket: " + IntegerToString(order.ticket), GetLastError());
    }
}
bool MoveFile(string source, string dest) {
    // Try FileClose first to ensure file isn't locked
    if (FileIsExist(dest)) {
        Print("[MoveFile] Destination already exists, deleting: ", dest);
        if (!FileDelete(dest)) {
            Print("[MoveFile] Failed to delete destination file");
            return false;
        }
    }
    
    // MQL4 has limited file operations - try reading and writing
    // This is a workaround since FileMove doesn't exist
    int readHandle = FileOpen(source, FILE_READ | FILE_BIN);
    if (readHandle == INVALID_HANDLE) {
        Print("[MoveFile] Cannot open source for reading: ", source);
        return false;
    }
    
    uint fileSize = (uint)FileSize(readHandle);
    if (fileSize <= 0) {
        FileClose(readHandle);
        Print("[MoveFile] Invalid file size");
        return false;
    }
    
    uchar buffer[];
    ArrayResize(buffer, fileSize);
    uint bytesRead = FileReadArray(readHandle, buffer, 0, fileSize);
    FileClose(readHandle);
    
    if (bytesRead != fileSize) {
        Print("[MoveFile] Failed to read entire file");
        return false;
    }
    
    int writeHandle = FileOpen(dest, FILE_WRITE | FILE_BIN);
    if (writeHandle == INVALID_HANDLE) {
        Print("[MoveFile] Cannot open destination for writing: ", dest);
        return false;
    }
    
    uint bytesWritten = FileWriteArray(writeHandle, buffer, 0, fileSize);
    FileClose(writeHandle);
    
    if (bytesWritten != fileSize) {
        Print("[MoveFile] Failed to write entire file");
        return false;
    }
    
    if (!FileDelete(source)) {
        Print("[MoveFile] File copied but failed to delete source: ", source);
        return false;
    }
    
    Print("[MoveFile] Successfully moved: ", source, " -> ", dest);
    return true;
}

//+------------------------------------------------------------------+
//| Write output file with msg_id and ticket                         |
//+------------------------------------------------------------------+
void WriteOutputFile(string msg_id, int ticket) {
    // MQL4 FileOpen uses paths RELATIVE to MQL4\Files\
    // Do NOT use absolute paths like TerminalInfoString(TERMINAL_DATA_PATH)
    string outputPath = OutputFolder + "\\" + msg_id + ".txt";
    
    Print("[WriteOutputFile] DEBUG - Attempting to write to: ", outputPath);
    
    int handle = FileOpen(outputPath, FILE_WRITE | FILE_TXT);
    if (handle != INVALID_HANDLE) {
        FileWriteString(handle, IntegerToString(ticket));
        FileClose(handle);
        Print("[WriteOutputFile] SUCCESS - Output file written: ", outputPath);
    } else {
        Print("[WriteOutputFile] ERROR - Failed to open file: ", outputPath, " | Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Import DLL for ShellExecute                                       |
//+------------------------------------------------------------------+
#import "shell32.dll"
int ShellExecuteW(int hwnd, string lpOperation, string lpFile, string lpParameters, string lpDirectory, int nShowCmd);
#import

#import "kernel32.dll"
int GetLastError();
#import