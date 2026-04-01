//+------------------------------------------------------------------+
//|                    Order Manager from JSON Files                 |
//|                        MetaTrader 5 Expert Advisor               |
//+------------------------------------------------------------------+
#property copyright "Bembe83"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string InputFolder = "input";
input string ArchiveInputFolder = "archive\\input";
input string OutputFolder = "output";
input string ArchiveOutputFolder = "archive\\output";
input int CheckInterval = 5000;

CTrade trade;

string LogFilePath = "orders_errors.log";

struct OrderData {
   string action;
   string msg_id;
   ulong ticket;
   string symbol;
   ENUM_ORDER_TYPE type;
   double volume;
   double price;
   double sl;
   double tp;
};

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

void OnDeinit(const int reason) {
   EventKillTimer();
}

void OnTick() {
}

void OnTimer() {
   ProcessFiles();
}

void ProcessFiles() {
   string inputPath = InputFolder + "\\";
   string archiveInputPath = ArchiveInputFolder + "\\";

   Print("[ProcessFiles] Checking folder: ", inputPath);

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

      // Support both formats:
      // 1) Legacy: type=BUY/SELL/BUYLIMIT/...
      // 2) Python generator: type=MARKET with side=BUY/SELL
      if (typeStr == "MARKET") {
         if (sideStr == "BUY") order.type = ORDER_TYPE_BUY;
         else if (sideStr == "SELL") order.type = ORDER_TYPE_SELL;
         else {
            Print("[ParseJSONFile] Invalid MARKET side: '", sideStr, "'");
            return false;
         }
      } else if (typeStr == "BUY") order.type = ORDER_TYPE_BUY;
      else if (typeStr == "SELL") order.type = ORDER_TYPE_SELL;
      else if (typeStr == "BUYLIMIT") order.type = ORDER_TYPE_BUY_LIMIT;
      else if (typeStr == "SELLLIMIT") order.type = ORDER_TYPE_SELL_LIMIT;
      else if (typeStr == "BUYSTOP") order.type = ORDER_TYPE_BUY_STOP;
      else if (typeStr == "SELLSTOP") order.type = ORDER_TYPE_SELL_STOP;
      else {
         Print("[ParseJSONFile] Invalid order type: '", typeStr, "'");
         return false;
      }

      order.volume = ExtractDoubleValue(json, "volume");
      if (order.type == ORDER_TYPE_BUY)
         order.price = SymbolInfoDouble(order.symbol, SYMBOL_ASK);
      else if (order.type == ORDER_TYPE_SELL)
         order.price = SymbolInfoDouble(order.symbol, SYMBOL_BID);
      else
         order.price = ExtractDoubleValue(json, "price");
      order.sl = ExtractDoubleValue(json, "sl");
      order.tp = ExtractDoubleValue(json, "tp");
   } else if (order.action == "UPDATE" || order.action == "CANCEL" || order.action == "CLOSE") {
      order.ticket = (ulong)ExtractIntValue(json, "ticket");
      if (order.ticket == 0) {
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
      double result = StringToDouble(value);
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
   double result = StringToDouble(value);
   Print("[ExtractDoubleValue] Key: ", key, " Value (numeric): ", value, " Result: ", result);
   return result;
}

long ExtractIntValue(string json, string key) {
   int start = 0;
   if (!FindJsonValueStart(json, key, start)) return 0;

   int end = start;
   if (StringGetCharacter(json, end) == '-') end++;
   while (end < StringLen(json) && (StringGetCharacter(json, end) >= '0' && StringGetCharacter(json, end) <= '9')) {
      end++;
   }

   string value = StringSubstr(json, start, end - start);
   return StringToInteger(value);
}

string ToUpper(string s) {
   string result = "";
   for (int i = 0; i < StringLen(s); i++) {
      int c = StringGetCharacter(s, i);
      if (c >= 'a' && c <= 'z') c -= 32;
      result += CharToString(uchar(c));
   }
   return result;
}

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

ENUM_ORDER_TYPE_FILLING GetFillingMode(string symbol) {
   long fillingMode = 0;
   if (!SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE, fillingMode)) {
      return ORDER_FILLING_FOK;
   }

   if ((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if ((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   if ((fillingMode & SYMBOL_FILLING_BOC) == SYMBOL_FILLING_BOC) return ORDER_FILLING_BOC;

   return ORDER_FILLING_FOK;
}

double NormalizePrice(string symbol, double price) {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
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
//| Send request and handle errors                                   |
//+------------------------------------------------------------------+
bool SendRequest(MqlTradeRequest &request, MqlTradeResult &result, string context, string msg_id = "") {
   ZeroMemory(result);
   if (!OrderSend(request, result)) {
      Print("[", context, "] ERROR - OrderSend failed | Error: ", GetLastError(), " | Retcode: ", result.retcode);
      if (msg_id != "") {
         LogError(context, msg_id, "OrderSend failed", (int)GetLastError());
      }
      return false;
   }

   if (result.retcode != TRADE_RETCODE_DONE &&
       result.retcode != TRADE_RETCODE_DONE_PARTIAL &&
       result.retcode != TRADE_RETCODE_PLACED) {
      Print("[", context, "] ERROR - Trade request rejected | Retcode: ", result.retcode, " | Comment: ", result.comment);
      if (msg_id != "") {
         LogError(context, msg_id, "Trade request rejected. Retcode: " + IntegerToString(result.retcode) + " | " + result.comment, result.retcode);
      }
      return false;
   }

   return true;
}

void CreateOrder(OrderData &order) {
   Print("[CreateOrder] DEBUG - Symbol: ", order.symbol, " | Type: ", EnumToString(order.type));
   Print("[CreateOrder] DEBUG - Volume: ", order.volume, " | Price: ", order.price);
   Print("[CreateOrder] DEBUG - SL: ", order.sl, " | TP: ", order.tp);

   if (!SymbolSelect(order.symbol, true)) {
      Print("[CreateOrder] ERROR - Failed to select symbol: ", order.symbol);
      LogError("CREATE", order.msg_id, "Failed to select symbol: " + order.symbol, (int)GetLastError());
      return;
   }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);

   request.symbol = order.symbol;
   request.volume = order.volume;
   request.type = order.type;
   request.sl = order.sl > 0.0 ? NormalizePrice(order.symbol, order.sl) : 0.0;
   request.tp = order.tp > 0.0 ? NormalizePrice(order.symbol, order.tp) : 0.0;
   request.deviation = 30;
   request.magic = 0;
   request.comment = "JSON Order";
   request.type_filling = GetFillingMode(order.symbol);
   request.type_time = ORDER_TIME_GTC;

   if (order.type == ORDER_TYPE_BUY || order.type == ORDER_TYPE_SELL) {
      request.action = TRADE_ACTION_DEAL;
      request.price = (order.type == ORDER_TYPE_BUY)
                    ? SymbolInfoDouble(order.symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(order.symbol, SYMBOL_BID);
   } else {
      request.action = TRADE_ACTION_PENDING;
      request.price = NormalizePrice(order.symbol, order.price);
   }

   if (!SendRequest(request, result, "CreateOrder", order.msg_id)) {
      return;
   }

   ulong ticket = (result.order > 0) ? result.order : result.deal;
   Print("[CreateOrder] SUCCESS - Order created with ticket: ", ticket);
   WriteOutputFile(order.msg_id, ticket);
}

bool UpdatePositionSLTP(ulong ticket, double sl, double tp, string msg_id = "") {
   if (!PositionSelectByTicket(ticket)) {
      if (msg_id != "") {
         LogError("UPDATE", msg_id, "Failed to select position, ticket: " + StringFormat("%I64u", ticket), (int)GetLastError());
      }
      return false;
   }

   string symbol = PositionGetString(POSITION_SYMBOL);

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = symbol;
   request.sl = sl > 0.0 ? NormalizePrice(symbol, sl) : 0.0;
   request.tp = tp > 0.0 ? NormalizePrice(symbol, tp) : 0.0;

   return SendRequest(request, result, "UpdateOrder", msg_id);
}

bool UpdatePendingOrder(OrderData &order) {
   if (!OrderSelect(order.ticket)) {
      LogError("UPDATE", order.msg_id, "Failed to select order, ticket: " + StringFormat("%I64u", order.ticket), (int)GetLastError());
      return false;
   }

   string symbol = OrderGetString(ORDER_SYMBOL);
   double currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);

   request.action = TRADE_ACTION_MODIFY;
   request.order = order.ticket;
   request.symbol = symbol;
   request.price = order.price > 0.0 ? NormalizePrice(symbol, order.price) : NormalizePrice(symbol, currentPrice);
   request.sl = order.sl > 0.0 ? NormalizePrice(symbol, order.sl) : 0.0;
   request.tp = order.tp > 0.0 ? NormalizePrice(symbol, order.tp) : 0.0;
   request.type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
   request.expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

   return SendRequest(request, result, "UpdateOrder", order.msg_id);
}

void UpdateOrder(OrderData &order) {
   Print("[UpdateOrder] DEBUG - Ticket: ", order.ticket, " | Price: ", order.price, " | SL: ", order.sl, " | TP: ", order.tp);

   if (PositionSelectByTicket(order.ticket)) {
      if (UpdatePositionSLTP(order.ticket, order.sl, order.tp, order.msg_id)) {
         Print("[UpdateOrder] SUCCESS - Position updated: ", order.ticket);
      } else {
         Print("[UpdateOrder] ERROR - Failed to update position: ", order.ticket);
         LogError("UPDATE", order.msg_id, "Failed to update position, ticket: " + StringFormat("%I64u", order.ticket), 0);
      }
      return;
   }

   if (OrderSelect(order.ticket)) {
      if (UpdatePendingOrder(order)) {
         Print("[UpdateOrder] SUCCESS - Pending order updated: ", order.ticket);
      } else {
         Print("[UpdateOrder] ERROR - Failed to update pending order: ", order.ticket);
         LogError("UPDATE", order.msg_id, "Failed to update pending order, ticket: " + StringFormat("%I64u", order.ticket), 0);
      }
      return;
   }

   Print("[UpdateOrder] ERROR - Ticket not found: ", order.ticket);
   LogError("UPDATE", order.msg_id, "Ticket not found: " + StringFormat("%I64u", order.ticket), (int)GetLastError());
}

void CancelOrder(OrderData &order) {
   Print("[CancelOrder] DEBUG - Ticket: ", order.ticket);

   if (PositionSelectByTicket(order.ticket)) {
      if (trade.PositionClose(order.ticket)) {
         Print("[CancelOrder] SUCCESS - Position closed: ", order.ticket);
      } else {
         int errorCode = trade.ResultRetcode();
         Print("[CancelOrder] ERROR - PositionClose failed | Retcode: ", errorCode, " | ", trade.ResultRetcodeDescription());
         LogError("CANCEL", order.msg_id, "PositionClose failed. Ticket: " + StringFormat("%I64u", order.ticket), errorCode);
      }
      return;
   }

   if (OrderSelect(order.ticket)) {
      if (trade.OrderDelete(order.ticket)) {
         Print("[CancelOrder] SUCCESS - Pending order deleted: ", order.ticket);
      } else {
         int errorCode = trade.ResultRetcode();
         Print("[CancelOrder] ERROR - OrderDelete failed | Retcode: ", errorCode, " | ", trade.ResultRetcodeDescription());
         LogError("CANCEL", order.msg_id, "OrderDelete failed. Ticket: " + StringFormat("%I64u", order.ticket), errorCode);
      }
      return;
   }

   Print("[CancelOrder] ERROR - Ticket not found: ", order.ticket);
   LogError("CANCEL", order.msg_id, "Ticket not found: " + StringFormat("%I64u", order.ticket), (int)GetLastError());
}

void CloseOrder(OrderData &order) {
   Print("[CloseOrder] DEBUG - Ticket: ", order.ticket);

   if (PositionSelectByTicket(order.ticket)) {
      if (trade.PositionClose(order.ticket)) {
         Print("[CloseOrder] SUCCESS - Position closed: ", order.ticket);
      } else {
         int errorCode = trade.ResultRetcode();
         Print("[CloseOrder] ERROR - PositionClose failed | Retcode: ", errorCode, " | ", trade.ResultRetcodeDescription());
         LogError("CLOSE", order.msg_id, "PositionClose failed. Ticket: " + StringFormat("%I64u", order.ticket), errorCode);
      }
      return;
   }

   if (OrderSelect(order.ticket)) {
      Print("[CloseOrder] ERROR - Cannot close a pending order, use CANCEL instead: ", order.ticket);
      LogError("CLOSE", order.msg_id, "Cannot close pending order. Use CANCEL instead. Ticket: " + StringFormat("%I64u", order.ticket), 0);
      return;
   }

   Print("[CloseOrder] ERROR - Ticket not found: ", order.ticket);
   LogError("CLOSE", order.msg_id, "Ticket not found: " + StringFormat("%I64u", order.ticket), (int)GetLastError());
}

bool MoveFile(string source, string dest) {
   if (FileIsExist(dest)) {
      Print("[MoveFile] Destination already exists, deleting: ", dest);
      if (!FileDelete(dest)) {
         Print("[MoveFile] Failed to delete destination file");
         return false;
      }
   }

   int readHandle = FileOpen(source, FILE_READ | FILE_BIN);
   if (readHandle == INVALID_HANDLE) {
      Print("[MoveFile] Cannot open source for reading: ", source);
      return false;
   }

   int fileSize = (int)FileSize(readHandle);
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

void WriteOutputFile(string msg_id, ulong ticket) {
   string outputPath = OutputFolder + "\\" + msg_id + ".txt";

   Print("[WriteOutputFile] DEBUG - Attempting to write to: ", outputPath);

   int handle = FileOpen(outputPath, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (handle != INVALID_HANDLE) {
      FileWriteString(handle, StringFormat("%I64u", ticket));
      FileClose(handle);
      Print("[WriteOutputFile] SUCCESS - Output file written: ", outputPath);
   } else {
      Print("[WriteOutputFile] ERROR - Failed to open file: ", outputPath, " | Error: ", GetLastError());
   }
}
