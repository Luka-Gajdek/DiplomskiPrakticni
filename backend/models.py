from pydantic import BaseModel
from typing import List, Optional


class ChatRequest(BaseModel):
    message: str
    context: str = ""


class ChatResponse(BaseModel):
    reply: str


class SalesRecord(BaseModel):
    date: str        # ISO format: YYYY-MM-DD
    quantity: float
    amount: float


class PredictRequest(BaseModel):
    item_no: str
    history: List[SalesRecord]
    forecast_days: int = 30


class PredictResponse(BaseModel):
    item_no: str
    predicted_quantity: float
    predicted_amount: float
    forecast_period: str


class ErrorResponse(BaseModel):
    error: str


class PaymentRecord(BaseModel):
    customer_no: str
    customer_posting_group: str
    invoice_amount: float
    payment_terms_days: int
    was_late: bool
    days_late: int


class OpenInvoice(BaseModel):
    customer_no: str
    document_no: str
    customer_posting_group: str
    invoice_amount: float
    payment_terms_days: int
    days_until_due: int


class LatePaymentRequest(BaseModel):
    training_data: List[PaymentRecord]
    invoices_to_predict: List[OpenInvoice]


class InvoicePrediction(BaseModel):
    document_no: str
    customer_no: str
    invoice_amount: float
    days_until_due: int
    will_be_late: bool
    probability: float
    expected_days_late: int


class LatePaymentResponse(BaseModel):
    predictions: List[InvoicePrediction]


class IntentRequest(BaseModel):
    message: str


class IntentResponse(BaseModel):
    intent: str   # "predict_sales" | "item_info" | "vacation" | "customer" | "chat"
    parameter: str = ""
    days: int = 30
