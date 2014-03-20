#'<brief desc>
#'
#'<full description>
#' @export
#' @import rzmq
#' @import uuid
#' @import digest
#' @importFrom rjson fromJSON toJSON
hb_reply <- function() {
    data <- receive.socket(hb_socket, unserialize = FALSE)
    send.socket(hb_socket, data, serialize = FALSE)
}

#'<brief desc>
#'
#'<full description>
#' @param msg_lst <what param does>
#' @export
sign_msg <- function(msg_lst) {
    concat <- paste(msg_lst, collapse = "")
    return(hmac(connection_info$key, concat, "sha256"))
}
#'<brief desc>
#'
#'<full description>
#' @param socket <what param does>
#' @export
recv_multipart <- function(socket) {
    parts <- rawToChar(receive.socket(socket, unserialize = FALSE))
    while (get.rcvmore(socket)) {
        parts <- append(parts, rawToChar(receive.socket(socket, unserialize = FALSE)))
    }
    return(parts)
}
#'<brief desc>
#'
#'<full description>
#' @param socket <what param does>
#' @param  parts <what param does>
#' @export
send_multipart <- function(socket, parts) {
    for (part in parts[1:(length(parts) - 1)]) {
        send.raw.string(socket, part, send.more = TRUE)
    }
    send.raw.string(socket, parts[length(parts)], send.more = FALSE)
}
#'<brief desc>
#'
#'<full description>
#' @param parts <what param does>
#' @import rjson
#' @export
wire_to_msg <- function(parts) {
    i <- 1
    # print(parts)
    while (parts[i] != "<IDS|MSG>") {
        i <- i + 1
    }
    signature <- parts[i + 1]
    expected_signature <- sign_msg(parts[(i + 2):(i + 5)])
    stopifnot(identical(signature, expected_signature))
    header <- fromJSON(parts[i + 2])
    parent_header <- fromJSON(parts[i + 3])
    metadata <- fromJSON(parts[i + 4])
    content <- fromJSON(parts[i + 5])
    if (i > 1) {
        identities <- parts[1:(i - 1)]
    } else {
        identities <- NULL
    }
    return(list(header = header, parent_header = parent_header, metadata = metadata, 
        content = content, identities = identities))
}
#'<brief desc>
#'
#'<full description>
#' @param msg <what param does>
#' @export
msg_to_wire <- function(msg) {
    bodyparts <- c(toJSON(msg$header), toJSON(msg$parent_header), toJSON(msg$metadata), 
        toJSON(msg$content))
    # Hack: an empty R list becomes [], not {}, which is what we want
    if (length(msg$metadata) == 0) {
        bodyparts[3] <- "{}"
    }
    signature <- sign_msg(bodyparts)
    # print(msg$identities)
    return(c(msg$identities, "<IDS|MSG>", signature, bodyparts))
}
#'<brief desc>
#'
#'<full description>
#' @param msg_type <what param does>
#' @param  parent_msg <what param does>
#' @export
new_reply <- function(msg_type, parent_msg) {
    header <- list(msg_id = UUIDgenerate(), username = parent_msg$header$username, 
        session = parent_msg$header$session, msg_type = msg_type)
    return(list(header = header, parent_header = parent_msg$header, identities = parent_msg$identities, 
        metadata = list()))
}
#'<brief desc>
#'
#'<full description>
#' @param msg_type <what param does>
#' @param  parent_msg <what param does>
#' @param  socket <what param does>
#' @param  content <what param does>
#' @export
send_response <- function(msg_type, parent_msg, socket, content) {
    msg <- new_reply(msg_type, parent_msg)
    msg$content <- content
    send_multipart(socket, msg_to_wire(msg))
}
#'<brief desc>
#'
#'<full description>
#' @param  <what param does>
#' @export
handle_shell <- function() {
    parts <- recv_multipart(shell_socket)
    msg <- wire_to_msg(parts)
    if (msg$header$msg_type == "execute_request") {
        execute(msg)
    } else if (msg$header$msg_type == "kernel_info_request") {
        kernel_info(msg)
    } else if (msg$header$msg_type == "history_request") {
        history(msg)
    } else {
        print(c("Got unhandled msg_type:", msg$header$msg_type))
    }
}

history <- function(request) {
  send_response("history_reply", request, shell_socket, list(history=list()))
}

exec.special = new.env()
assign("counter", 1, envir=exec.special)
userenv = new.env()

execute <- function(request) {
  execution_count = get("counter", envir=exec.special)
  send_response("status", request, iopub_socket, list(execution_state="busy"))
  send_response("pyin", request, iopub_socket,
                list(code=request$code, execution_count=execution_count))

  silent = request$content$silent
  if (silent) {
    code = request$contents$code
  } else {
    code = sprintf("withVisible({%s})", request$content$code)
  }
  
  err = tryCatch({
    expr = parse(text=code)
    output_conn = textConnection("output", "w")
    sink(output_conn)
    result = eval(expr, envir=userenv)
    list(ename=NULL)  # Result of expression: error status
  }, error = function(e) {
    return(list(ename="ERROR", evalue=toString(e), traceback=list(toString(e))))
  }, finally = {
    sink()
    close(output_conn)
  })

  if (!silent) {
      if (!is.null(err$ename)) {
        send_response("pyerr", request, iopub_socket,
                      c(err, list(execution_count=execution_count)))
      } else if (result$visible) {
        data = list()
        data['text/plain'] = capture.output(print(result$value))
        send_response("pyout", request, iopub_socket,
                  list(data=data, metadata=list(), execution_count=execution_count))
      }

      if (length(output) > 0) {
        send_response("stream", request, iopub_socket,
                      list(name="stdout", data=output))
      }
  }
  
  send_response("status", request, iopub_socket, list(execution_state="idle"))
  
  if (!is.null(err$ename)) {
    reply_content = c(err, list(status='error', execution_count=execution_count))
  } else {
    reply_content = list(status='ok', execution_count=execution_count,
                  payload=list(), user_variables=list(), user_expressions=list())
  }
  send_response("execute_reply", request, shell_socket, reply_content)
  
  if (!silent) {
    assign("counter", execution_count+1, envir=exec.special)
  }
}

kernel_info <- function(request) {
  send_response("kernel_info_reply", request, shell_socket, 
                list(protocol_version=c(4, 0), language="R"))
}

handle_control <- function() {
  parts = recv_multipart(control_socket)
  msg = wire_to_msg(parts)
  if (msg$header$msg_type == "shutdown_request") {
    shutdown(msg)
  } else {
    print(c("Unhandled control message, msg_type:", msg$header$msg_type))
  }
}

shutdown <- function(request) {
  send_response('shutdown_reply', request, control_socket,
                list(restart=request$content$restart))
  stop("Shut down by frontend.")
}

main <- function(argv=NULL) {
    if (is.null(argv)) {
      argv <- commandArgs(trailingOnly = TRUE)
    }
    connection_info <<- fromJSON(file = argv[1])
    print(connection_info)
    url <- paste(connection_info$transport, "://", connection_info$ip, sep = "")
    url_with_port <- function(port_name) {
        return(paste(url, ":", connection_info[port_name], sep = ""))
    }

    # ZMQ Socket setup
    
    zmqctx <- init.context()
    hb_socket <<- init.socket(zmqctx, "ZMQ_REP")
    iopub_socket <<- init.socket(zmqctx, "ZMQ_DEALER")
    control_socket <<- init.socket(zmqctx, "ZMQ_DEALER")
    stdin_socket <<- init.socket(zmqctx, "ZMQ_DEALER")
    shell_socket <<- init.socket(zmqctx, "ZMQ_DEALER")
    bind.socket(hb_socket, url_with_port("hb_port"))
    bind.socket(iopub_socket, url_with_port("iopub_port"))
    bind.socket(control_socket, url_with_port("control_port"))
    bind.socket(stdin_socket, url_with_port("stdin_port"))
    bind.socket(shell_socket, url_with_port("shell_port"))

	# Loop
    while (1) {
        events <- poll.socket(list(hb_socket, shell_socket, control_socket),
                              list("read", "read", "read"), timeout = -1L)
        if (events[[1]]$read) {
            # heartbeat
            hb_reply()
        }
        if (events[[2]]$read) {
            # Shell socket
            handle_shell()
        }

        if (events[[3]]$read) {  # Control socket
            handle_control()
        }
    }
}
