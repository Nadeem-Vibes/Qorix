const compliments = [
	"You made a web page. That is genuinely cool.",
	"Every expert started with a page exactly like this one.",
	"Your future self will be glad you tried.",
	"This button works, which means your JavaScript works too.",
];

const button = document.querySelector("#cheer");
const message = document.querySelector("#message");

button.addEventListener("click", () => {
	const pick = compliments[Math.floor(Math.random() * compliments.length)];
	message.textContent = pick;
});

message.textContent = "Press the button.";
