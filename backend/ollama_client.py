import httpx
import json
import re

OLLAMA_BASE_URL = "http://localhost:11434"
MODEL_NAME = "llama3:8b"

INTENT_PROMPT = """You are an intent classifier for a Business Central ERP assistant.

Classify the user message into exactly one of these intents:
- predict_sales   : user wants a sales forecast or prediction for an item
- stock_duration  : user asks how long the current stock/inventory of an item will last
- item_info       : user asks about an item, product, stock, inventory, price
- vacation        : user asks about vacation days, holidays, absence, leave for an employee
- customer        : user asks about a customer or client
- late_payment    : user asks whether an invoice or customer will pay on time, payment risk, late payment prediction
- chat            : anything else (greetings, general questions, etc.)

For the parameter, extract ONLY the core identifying value — not surrounding words:
- For items: extract only the item name or number (e.g. "Berlin Chair", "1900-S"), never phrases like "current stash of Berlin chairs"
- For employees: extract only the person's name
- For customers: extract only the customer name or number

For predict_sales, also extract the number of forecast days if mentioned (default to 30 if not specified).

Examples:
"how long can we expect current stash of berlin chairs to last?" -> {"intent": "stock_duration", "parameter": "berlin chairs", "days": 30}
"predict sales for item 1900-S for next 60 days" -> {"intent": "predict_sales", "parameter": "1900-S", "days": 60}
"can you predict sales for 1896-S for next 100 days?" -> {"intent": "predict_sales", "parameter": "1896-S", "days": 100}
"predict sales for 1900-S" -> {"intent": "predict_sales", "parameter": "1900-S", "days": 30}
"how much of tokyo chair do we have?" -> {"intent": "item_info", "parameter": "tokyo chair", "days": 30}
"how many vacation days does John Smith have left?" -> {"intent": "vacation", "parameter": "John Smith", "days": 30}
"will Adatum Corporation pay their invoices on time?" -> {"intent": "late_payment", "parameter": "Adatum Corporation", "days": 30}
"what is the payment risk for customer 10000?" -> {"intent": "late_payment", "parameter": "10000", "days": 30}
"predict late payments" -> {"intent": "late_payment", "parameter": "", "days": 30}

Respond ONLY with a JSON object, no explanation:
{"intent": "<intent>", "parameter": "<parameter>", "days": <number>}

User message: """

SYSTEM_PROMPT = (
    "You are a helpful Business Central ERP assistant. "
    "Answer questions concisely and accurately using plain prose — no bullet points, no asterisks, no markdown formatting. "
    "When context data is provided (JSON), use it to give precise answers but never mention JSON field names, variable names, or technical flags from the data. "
    "Translate data into natural human language. For example, do not say 'will_be_late is true' — say 'is expected to be paid late'. "
    "Keep answers short and professional."
)


async def detect_intent(message: str) -> dict:
    """Ask Llama3 to classify the user's intent and extract the key parameter."""
    payload = {
        "model": MODEL_NAME,
        "prompt": INTENT_PROMPT + message,
        "stream": False,
        "options": {
            "temperature": 0.0,
            "num_predict": 64,
        }
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.post(f"{OLLAMA_BASE_URL}/api/generate", json=payload)
        response.raise_for_status()
        raw = response.json().get("response", "").strip()

    # Extract JSON from response
    match = re.search(r'\{.*?\}', raw, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())
        except json.JSONDecodeError:
            pass

    return {"intent": "chat", "parameter": "", "days": 30}


async def generate(message: str, context: str = "") -> str:
    """Send a prompt to Ollama and return the response text."""
    prompt_parts = []

    if context:
        prompt_parts.append(f"Context data from Business Central:\n{context}\n")

    prompt_parts.append(f"User: {message}\nAssistant:")

    full_prompt = "\n".join(prompt_parts)

    payload = {
        "model": MODEL_NAME,
        "prompt": full_prompt,
        "system": SYSTEM_PROMPT,
        "stream": False,
        "options": {
            "temperature": 0.3,
            "num_predict": 512,
        }
    }

    async with httpx.AsyncClient(timeout=120.0) as client:
        response = await client.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json=payload
        )
        response.raise_for_status()
        data = response.json()
        return data.get("response", "").strip()
