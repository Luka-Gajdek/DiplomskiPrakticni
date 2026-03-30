import os
from fastapi import FastAPI, Header, HTTPException, status
from dotenv import load_dotenv

from models import (
    ChatRequest, ChatResponse, PredictRequest, PredictResponse, ErrorResponse,
    IntentRequest, IntentResponse, LatePaymentRequest, LatePaymentResponse,
)
import ollama_client
import sales_prediction
import late_payment_prediction

load_dotenv()

API_KEY = os.getenv("API_KEY", "")

app = FastAPI(title="BC AI Assistant Backend", version="1.0.0")


def _verify_api_key(x_api_key: str = Header(default="")):
    if not API_KEY:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="API_KEY not configured on server. Set it in .env",
        )
    if x_api_key != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key",
        )


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest, x_api_key: str = Header(default="")):
    _verify_api_key(x_api_key)
    try:
        reply = await ollama_client.generate(request.message, request.context)
        return ChatResponse(reply=reply)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Ollama error: {exc}. Ensure ollama is running and llama3:8b is pulled.",
        )


@app.post("/detect-intent", response_model=IntentResponse)
async def detect_intent(request: IntentRequest, x_api_key: str = Header(default="")):
    _verify_api_key(x_api_key)
    result = await ollama_client.detect_intent(request.message)
    return IntentResponse(
        intent=result.get("intent", "chat"),
        parameter=result.get("parameter", ""),
        days=result.get("days", 30),
    )


@app.get("/company-rules")
async def company_rules(x_api_key: str = Header(default="")):
    _verify_api_key(x_api_key)
    rules_path = os.path.join(os.path.dirname(__file__), "..", "BCChatbot", "company_rules.md")
    try:
        with open(rules_path, "r", encoding="utf-8") as f:
            rules = f.read()
        return {"rules": rules}
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="company_rules.md not found")


@app.post("/predict-sales")
async def predict_sales(request: PredictRequest, x_api_key: str = Header(default="")):
    _verify_api_key(x_api_key)

    history_dicts = [record.model_dump() for record in request.history]

    result = sales_prediction.predict(request.item_no, history_dicts, days=request.forecast_days)

    if "error" in result:
        return result  # Return error JSON with 200 so BC can parse the message

    return PredictResponse(**result)


@app.post("/predict-late-payment")
async def predict_late_payment(request: LatePaymentRequest, x_api_key: str = Header(default="")):
    _verify_api_key(x_api_key)

    training_dicts = [r.model_dump() for r in request.training_data]
    predict_dicts = [r.model_dump() for r in request.invoices_to_predict]

    result = late_payment_prediction.predict(training_dicts, predict_dicts)

    if "error" in result:
        return result

    return LatePaymentResponse(**result)
