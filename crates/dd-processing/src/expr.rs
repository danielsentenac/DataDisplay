//! User-defined channel maths: a small expression evaluator replacing the
//! original's runtime-compiled C "UserOp" strings (e.g. `ch0*ch1`,
//! `sqrt(ch0^2 + ch1^2)`, `20*log10(abs(ch0))`).
//!
//! Variables `ch0`..`chN` refer to the input series by position. Supported:
//! `+ - * / ^`, unary minus, parentheses, constants `pi`/`e`, and functions
//! sin cos tan asin acos atan sinh cosh tanh exp log log10 sqrt abs floor
//! ceil, plus two-argument min max pow atan2.

use dd_domain::{ChannelDescriptor, Series1D, TimeAxis};

use crate::error::{series_sample_rate_hz, ProcessingError};

#[derive(Clone, Debug, PartialEq)]
enum Token {
    Number(f64),
    Identifier(String),
    Plus,
    Minus,
    Star,
    Slash,
    Caret,
    LeftParen,
    RightParen,
    Comma,
}

#[derive(Clone, Debug, PartialEq)]
enum Expr {
    Number(f64),
    Variable(usize),
    Unary(Box<Expr>),
    Binary(char, Box<Expr>, Box<Expr>),
    Call(String, Vec<Expr>),
}

fn invalid(message: impl Into<String>) -> ProcessingError {
    ProcessingError::InvalidParams(message.into())
}

fn tokenize(input: &str) -> Result<Vec<Token>, ProcessingError> {
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();
    while let Some(&c) = chars.peek() {
        match c {
            ' ' | '\t' | '\n' | '\r' => {
                chars.next();
            }
            '+' => {
                chars.next();
                tokens.push(Token::Plus);
            }
            '-' => {
                chars.next();
                tokens.push(Token::Minus);
            }
            '*' => {
                chars.next();
                tokens.push(Token::Star);
            }
            '/' => {
                chars.next();
                tokens.push(Token::Slash);
            }
            '^' => {
                chars.next();
                tokens.push(Token::Caret);
            }
            '(' => {
                chars.next();
                tokens.push(Token::LeftParen);
            }
            ')' => {
                chars.next();
                tokens.push(Token::RightParen);
            }
            ',' => {
                chars.next();
                tokens.push(Token::Comma);
            }
            '0'..='9' | '.' => {
                let mut text = String::new();
                while let Some(&d) = chars.peek() {
                    if d.is_ascii_digit() || d == '.' {
                        text.push(d);
                        chars.next();
                    } else if (d == 'e' || d == 'E')
                        && !text.is_empty()
                        && !text.contains(['e', 'E'])
                    {
                        text.push(d);
                        chars.next();
                        if let Some(&sign) = chars.peek() {
                            if sign == '+' || sign == '-' {
                                text.push(sign);
                                chars.next();
                            }
                        }
                    } else {
                        break;
                    }
                }
                let value = text
                    .parse::<f64>()
                    .map_err(|_| invalid(format!("invalid number `{text}` in expression")))?;
                tokens.push(Token::Number(value));
            }
            'a'..='z' | 'A'..='Z' | '_' => {
                let mut name = String::new();
                while let Some(&d) = chars.peek() {
                    if d.is_ascii_alphanumeric() || d == '_' {
                        name.push(d);
                        chars.next();
                    } else {
                        break;
                    }
                }
                tokens.push(Token::Identifier(name));
            }
            other => return Err(invalid(format!("unexpected character `{other}` in expression"))),
        }
    }
    Ok(tokens)
}

struct Parser {
    tokens: Vec<Token>,
    position: usize,
    input_count: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.position)
    }

    fn next(&mut self) -> Option<Token> {
        let token = self.tokens.get(self.position).cloned();
        if token.is_some() {
            self.position += 1;
        }
        token
    }

    /// Pratt parser: `min_power` is the binding power floor.
    fn parse_expr(&mut self, min_power: u8) -> Result<Expr, ProcessingError> {
        let mut left = self.parse_prefix()?;
        loop {
            let (op, power, right_assoc) = match self.peek() {
                Some(Token::Plus) => ('+', 1, false),
                Some(Token::Minus) => ('-', 1, false),
                Some(Token::Star) => ('*', 2, false),
                Some(Token::Slash) => ('/', 2, false),
                Some(Token::Caret) => ('^', 3, true),
                _ => break,
            };
            if power < min_power {
                break;
            }
            self.next();
            let next_min = if right_assoc { power } else { power + 1 };
            let right = self.parse_expr(next_min)?;
            left = Expr::Binary(op, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_prefix(&mut self) -> Result<Expr, ProcessingError> {
        match self.next() {
            Some(Token::Number(value)) => Ok(Expr::Number(value)),
            Some(Token::Minus) => Ok(Expr::Unary(Box::new(self.parse_expr(4)?))),
            Some(Token::Plus) => self.parse_expr(4),
            Some(Token::LeftParen) => {
                let inner = self.parse_expr(0)?;
                match self.next() {
                    Some(Token::RightParen) => Ok(inner),
                    _ => Err(invalid("missing closing parenthesis in expression")),
                }
            }
            Some(Token::Identifier(name)) => self.parse_identifier(name),
            other => Err(invalid(format!(
                "unexpected token in expression: {other:?}"
            ))),
        }
    }

    fn parse_identifier(&mut self, name: String) -> Result<Expr, ProcessingError> {
        if let Some(index_text) = name.strip_prefix("ch") {
            if let Ok(index) = index_text.parse::<usize>() {
                if index >= self.input_count {
                    return Err(invalid(format!(
                        "expression references `{name}` but only {} channel(s) are given",
                        self.input_count
                    )));
                }
                return Ok(Expr::Variable(index));
            }
        }
        match name.as_str() {
            "pi" => return Ok(Expr::Number(std::f64::consts::PI)),
            "e" => return Ok(Expr::Number(std::f64::consts::E)),
            _ => {}
        }

        if self.peek() != Some(&Token::LeftParen) {
            return Err(invalid(format!("unknown identifier `{name}` in expression")));
        }
        self.next();
        let mut arguments = vec![self.parse_expr(0)?];
        while self.peek() == Some(&Token::Comma) {
            self.next();
            arguments.push(self.parse_expr(0)?);
        }
        if self.next() != Some(Token::RightParen) {
            return Err(invalid(format!("missing `)` after arguments of `{name}`")));
        }

        let expected_args = match name.as_str() {
            "sin" | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh"
            | "exp" | "log" | "log10" | "sqrt" | "abs" | "floor" | "ceil" => 1,
            "min" | "max" | "pow" | "atan2" => 2,
            _ => return Err(invalid(format!("unknown function `{name}` in expression"))),
        };
        if arguments.len() != expected_args {
            return Err(invalid(format!(
                "function `{name}` takes {expected_args} argument(s), got {}",
                arguments.len()
            )));
        }
        Ok(Expr::Call(name, arguments))
    }
}

fn evaluate(expr: &Expr, inputs: &[&Series1D], index: usize) -> f64 {
    match expr {
        Expr::Number(value) => *value,
        Expr::Variable(input) => inputs[*input].values[index],
        Expr::Unary(inner) => -evaluate(inner, inputs, index),
        Expr::Binary(op, left, right) => {
            let a = evaluate(left, inputs, index);
            let b = evaluate(right, inputs, index);
            match op {
                '+' => a + b,
                '-' => a - b,
                '*' => a * b,
                '/' => a / b,
                _ => a.powf(b),
            }
        }
        Expr::Call(name, arguments) => {
            let a = evaluate(&arguments[0], inputs, index);
            match name.as_str() {
                "sin" => a.sin(),
                "cos" => a.cos(),
                "tan" => a.tan(),
                "asin" => a.asin(),
                "acos" => a.acos(),
                "atan" => a.atan(),
                "sinh" => a.sinh(),
                "cosh" => a.cosh(),
                "tanh" => a.tanh(),
                "exp" => a.exp(),
                "log" => a.ln(),
                "log10" => a.log10(),
                "sqrt" => a.sqrt(),
                "abs" => a.abs(),
                "floor" => a.floor(),
                "ceil" => a.ceil(),
                two_arg => {
                    let b = evaluate(&arguments[1], inputs, index);
                    match two_arg {
                        "min" => a.min(b),
                        "max" => a.max(b),
                        "pow" => a.powf(b),
                        _ => a.atan2(b),
                    }
                }
            }
        }
    }
}

/// Evaluate a channel-maths expression sample-by-sample over the inputs.
/// All inputs must share the sample rate; they are truncated to the shortest.
pub fn evaluate_expression(
    expression: &str,
    inputs: &[&Series1D],
) -> Result<Series1D, ProcessingError> {
    if inputs.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let rate = series_sample_rate_hz(inputs[0])?;
    for input in &inputs[1..] {
        let other = series_sample_rate_hz(input)?;
        if ((rate - other) / rate).abs() > 1e-6 {
            return Err(ProcessingError::MismatchedInputs(format!(
                "expression inputs have different sample rates: {rate} Hz vs {other} Hz \
                 (resample first)"
            )));
        }
    }

    let tokens = tokenize(expression)?;
    if tokens.is_empty() {
        return Err(invalid("expression is empty"));
    }
    let mut parser = Parser {
        tokens,
        position: 0,
        input_count: inputs.len(),
    };
    let ast = parser.parse_expr(0)?;
    if parser.position != parser.tokens.len() {
        return Err(invalid(format!(
            "unexpected trailing input in expression `{expression}`"
        )));
    }

    let len = inputs.iter().map(|input| input.len()).min().unwrap_or(0);
    if len == 0 {
        return Err(ProcessingError::EmptyInput);
    }
    let values: Vec<f64> = (0..len).map(|index| evaluate(&ast, inputs, index)).collect();

    let axis = match &inputs[0].axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            ..
        } => TimeAxis::Regular {
            start_ns: *start_ns,
            sample_period_ns: *sample_period_ns,
            len,
        },
        TimeAxis::Irregular { timestamps_ns } => TimeAxis::Irregular {
            timestamps_ns: timestamps_ns.iter().copied().take(len).collect(),
        },
    };

    let mut channel = ChannelDescriptor::new(
        format!("expr({expression})"),
        expression.trim().to_string(),
    );
    channel.sample_rate_hz = inputs[0].channel.sample_rate_hz;
    let mut metadata = inputs[0].metadata.clone();
    metadata.insert("dd_expression".to_string(), expression.trim().to_string());

    Ok(Series1D {
        channel,
        axis,
        values,
        metadata,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use dd_domain::Metadata;

    fn series(values: Vec<f64>) -> Series1D {
        let mut channel = ChannelDescriptor::new("ch", "ch");
        channel.sample_rate_hz = Some(1000.0);
        let len = values.len();
        Series1D {
            channel,
            axis: TimeAxis::Regular {
                start_ns: 0,
                sample_period_ns: 1_000_000,
                len,
            },
            values,
            metadata: Metadata::new(),
        }
    }

    #[test]
    fn arithmetic_precedence_and_functions() {
        let a = series(vec![1.0, 2.0, 3.0]);
        let b = series(vec![4.0, 5.0, 6.0]);

        let sum = evaluate_expression("ch0 + 2*ch1", &[&a, &b]).unwrap();
        assert_eq!(sum.values, vec![9.0, 12.0, 15.0]);

        let quadrature = evaluate_expression("sqrt(ch0^2 + ch1^2)", &[&a, &b]).unwrap();
        assert!((quadrature.values[0] - (17.0f64).sqrt()).abs() < 1e-12);

        let power = evaluate_expression("2^ch0^2", &[&a]).unwrap();
        // Right-associative: 2^(1^2), 2^(2^2), 2^(3^2)
        assert_eq!(power.values, vec![2.0, 16.0, 512.0]);

        let negated = evaluate_expression("-ch0 + 1", &[&a]).unwrap();
        assert_eq!(negated.values, vec![0.0, -1.0, -2.0]);

        let two_arg = evaluate_expression("max(ch0, ch1) - min(ch0, 2)", &[&a, &b]).unwrap();
        assert_eq!(two_arg.values, vec![3.0, 3.0, 4.0]);

        let constant = evaluate_expression("cos(pi)", &[&a]).unwrap();
        assert!((constant.values[1] + 1.0).abs() < 1e-12);
    }

    #[test]
    fn truncates_to_shortest_input() {
        let a = series(vec![1.0, 2.0, 3.0, 4.0]);
        let b = series(vec![10.0, 20.0]);
        let result = evaluate_expression("ch0 * ch1", &[&a, &b]).unwrap();
        assert_eq!(result.values, vec![10.0, 40.0]);
        assert_eq!(result.axis.len(), 2);
    }

    #[test]
    fn rejects_bad_expressions() {
        let a = series(vec![1.0]);
        assert!(evaluate_expression("ch1 + 1", &[&a]).is_err());
        assert!(evaluate_expression("foo(ch0)", &[&a]).is_err());
        assert!(evaluate_expression("ch0 +", &[&a]).is_err());
        assert!(evaluate_expression("(ch0", &[&a]).is_err());
        assert!(evaluate_expression("ch0 1", &[&a]).is_err());
        assert!(evaluate_expression("", &[&a]).is_err());
        assert!(evaluate_expression("min(ch0)", &[&a]).is_err());
    }
}
