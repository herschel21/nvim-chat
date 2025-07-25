import pynvim
import socket
import threading
import json
import time
import queue
from datetime import datetime
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
import base64

@pynvim.plugin
class NvimChatPlugin:
    def __init__(self, nvim):
        self.nvim = nvim
        self.socket = None
        self.username = None
        self.connected = False
        self.cipher = None
        self.running = False
        self.message_queue = queue.Queue()
        self.listener_thread = None

        # Set initial connection status
        self.nvim.vars['chat_connected'] = False

        # Start message processor
        self.processor_thread = threading.Thread(target=self._process_messages, daemon=True)
        self.processor_thread.start()

    def _generate_cipher(self, password):
        """Generate Fernet cipher from password"""
        try:
            password_bytes = password.encode()
            salt = b'stable_salt_for_room'
            kdf = PBKDF2HMAC(
                algorithm=hashes.SHA256(),
                length=32,
                salt=salt,
                iterations=100000,
            )
            key = base64.urlsafe_b64encode(kdf.derive(password_bytes))
            return Fernet(key)
        except Exception as e:
            self.nvim.err_write(f"Cipher generation error: {e}\n")
            return None

    def _process_messages(self):
        """Process messages from queue and update UI"""
        while True:
            try:
                msg_type, data = self.message_queue.get(timeout=1.0)
                if msg_type == 'message':
                    self.nvim.async_call(self._handle_message, data)
                elif msg_type == 'history':
                    self.nvim.async_call(self._handle_history, data)
                elif msg_type == 'status':
                    self.nvim.async_call(self._update_status, data)
                elif msg_type == 'error':
                    self.nvim.async_call(self._show_error, data)
                elif msg_type == 'connection_status':
                    self.nvim.async_call(self._update_connection_status, data)
            except queue.Empty:
                continue
            except Exception as e:
                self.nvim.err_write(f"Message processor error: {e}\n")

    def _handle_message(self, msg_data):
        """Handle incoming message"""
        try:
            # Decrypt message if encrypted
            if msg_data.get('encrypted', False) and self.cipher:
                try:
                    msg_data['message'] = self.cipher.decrypt(msg_data['message'].encode()).decode()
                except:
                    msg_data['message'] = "[DECRYPTION_ERROR]"

            # Add to UI
            msg_data['is_own'] = msg_data.get('username') == self.username
            self._safe_ui_call('add_message', msg_data)
        except Exception as e:
            self.nvim.err_write(f"Error handling message: {e}\n")

    def _handle_history(self, history_data):
        """Handle history messages"""
        try:
            self.nvim.out_write(f"Received {len(history_data)} history messages\n")
            
            # Clear chat window first
            self._safe_ui_call('clear_chat')
            
            # Add each history message
            for msg in history_data:
                # Decrypt if needed
                if msg.get('encrypted', False) and self.cipher:
                    try:
                        msg['message'] = self.cipher.decrypt(msg['message'].encode()).decode()
                    except:
                        msg['message'] = "[DECRYPTION_ERROR]"
                
                # Set ownership
                msg['is_own'] = msg.get('username') == self.username
                
                # Add to UI
                self._safe_ui_call('add_message', msg)
                
        except Exception as e:
            self.nvim.err_write(f"Error handling history: {e}\n")

    def _update_connection_status(self, connected):
        """Update connection status"""
        self.nvim.vars['chat_connected'] = connected
        self._safe_ui_call('update_status', 'Connection status updated')

    def _safe_ui_call(self, method_name, *args):
        """Safely call UI methods with error handling"""
        try:
            lua_code = f"""
            local ui = require('nvim-chat.ui')
            if ui and ui.{method_name} then
                ui.{method_name}(...)
            end
            """
            self.nvim.exec_lua(lua_code, *args)
        except Exception as e:
            self.nvim.err_write(f"UI call error ({method_name}): {e}\n")

    def _update_status(self, message):
        """Update status"""
        try:
            self.nvim.command(f'echomsg "Chat: {message}"')
        except Exception as e:
            self.nvim.err_write(f"Status update error: {e}\n")

    def _show_error(self, message):
        """Show error message"""
        self.nvim.err_write(f"Chat Error: {message}\n")

    def _listen_for_messages(self):
        """Listen for incoming messages"""
        buffer = ""
        while self.running and self.connected:
            try:
                self.socket.settimeout(1.0)
                data = self.socket.recv(4096).decode()
                if not data:
                    break

                buffer += data
                while '\n' in buffer:
                    line, buffer = buffer.split('\n', 1)
                    if line.strip():
                        try:
                            msg_data = json.loads(line.strip())
                            
                            # Handle different message types
                            if msg_data.get('type') == 'history_response':
                                self.message_queue.put(('history', msg_data.get('messages', [])))
                            elif msg_data.get('type') == 'search_response':
                                self.message_queue.put(('history', msg_data.get('results', [])))
                            else:
                                self.message_queue.put(('message', msg_data))
                                
                        except json.JSONDecodeError:
                            continue

            except socket.timeout:
                continue
            except socket.error:
                break
            except Exception as e:
                self.message_queue.put(('error', f"Error receiving message: {e}"))
                break

        self.connected = False
        self.message_queue.put(('connection_status', False))
        self.message_queue.put(('status', "Disconnected from server"))

    @pynvim.function("ChatConnect", sync=True)
    def connect(self, args):
        """Connect to chat server"""
        if self.connected:
            self.nvim.out_write("Already connected!\n")
            return

        try:
            # Get configuration
            host = 'localhost'
            port = 12345
            password = 'root'  # Changed to match your server

            # Try to get config from global variables
            try:
                if hasattr(self.nvim.vars, 'nvim_chat_host'):
                    host = str(self.nvim.vars.nvim_chat_host)
                if hasattr(self.nvim.vars, 'nvim_chat_port'):
                    port = int(self.nvim.vars.nvim_chat_port)
                if hasattr(self.nvim.vars, 'nvim_chat_password'):
                    password = str(self.nvim.vars.nvim_chat_password)
            except Exception as e:
                self.nvim.err_write(f"Config error: {e}\n")

            # Get username
            try:
                self.username = self.nvim.call('input', 'Username: ')
                if not self.username:
                    self.nvim.err_write("Username required!\n")
                    return
            except Exception as e:
                self.nvim.err_write(f"Username input error: {e}\n")
                return

            try:
                # Create socket and connect
                self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.socket.settimeout(10.0)
                self.socket.connect((host, port))

                # Generate cipher
                self.cipher = self._generate_cipher(password)
                if not self.cipher:
                    self.nvim.err_write("Failed to generate encryption cipher\n")
                    return

                # Send authentication
                auth_data = {
                    'username': self.username,
                    'password': password
                }
                
                self.socket.send(json.dumps(auth_data).encode())

                # Receive response
                response_data = self.socket.recv(1024).decode()
                response = json.loads(response_data)

                if response['status'] == 'success':
                    self.username = response['username']
                    self.connected = True
                    self.running = True
                    self.socket.settimeout(None)

                    # Update connection status
                    self.message_queue.put(('connection_status', True))

                    # Start listener thread
                    self.listener_thread = threading.Thread(target=self._listen_for_messages, daemon=True)
                    self.listener_thread.start()

                    # Create UI if not open
                    try:
                        self._safe_ui_call('create_chat_window')
                    except Exception as e:
                        self.nvim.err_write(f"UI creation error: {e}\n")

                    self.nvim.out_write(f"Connected as {self.username}\n")
                    self.message_queue.put(('status', f"Connected as {self.username}"))
                else:
                    self.nvim.err_write(f"Connection failed: {response['message']}\n")

            except Exception as e:
                self.nvim.err_write(f"Connection error: {e}\n")

        except Exception as e:
            self.nvim.err_write(f"General connection error: {e}\n")

    @pynvim.function("ChatDisconnect", sync=True)
    def disconnect(self, args):
        """Disconnect from server"""
        self.running = False
        self.connected = False
        
        if self.socket:
            try:
                self.socket.close()
            except:
                pass
            self.socket = None

        self.message_queue.put(('connection_status', False))
        self.message_queue.put(('status', "Disconnected from server"))
        self.nvim.out_write("Disconnected from chat server\n")

    @pynvim.function("ChatToggle", sync=True)
    def toggle(self, args):
        """Toggle chat window"""
        try:
            self._safe_ui_call('toggle')
        except Exception as e:
            self.nvim.err_write(f"Toggle error: {e}\n")

    @pynvim.function("ChatSend", sync=True)
    def send_message(self, args):
        """Send message to server"""
        if not self.connected or not self.socket:
            self.nvim.err_write("Not connected to server\n")
            return

        message = ' '.join(args) if isinstance(args, list) else str(args)
        if not message.strip():
            return

        try:
            encrypted_message = self.cipher.encrypt(message.encode()).decode()
            msg_data = {
                'type': 'message',
                'message': encrypted_message
            }
            self.socket.send(json.dumps(msg_data).encode())
            self.message_queue.put(('status', f"Sent: {message[:30]}..."))
        except Exception as e:
            self.nvim.err_write(f"Error sending message: {e}\n")

    @pynvim.function("ChatHistory", sync=True)
    def request_history(self, args):
        """Request chat history"""
        if not self.connected or not self.socket:
            self.nvim.err_write("Not connected to server\n")
            return

        limit = args[0] if args and len(args) > 0 else 50

        try:
            history_request = {
                'type': 'history_request',
                'limit': limit,
                'offset': 0
            }
            self.socket.send(json.dumps(history_request).encode())
            self.nvim.out_write(f"Requesting {limit} messages from history...\n")
            self.message_queue.put(('status', f"Requested {limit} messages from history"))
        except Exception as e:
            self.nvim.err_write(f"Error requesting history: {e}\n")

    @pynvim.function("ChatSearch", sync=True)
    def search_chat(self, args):
        """Search chat history"""
        if not self.connected or not self.socket:
            self.nvim.err_write("Not connected to server\n")
            return

        if not args or not args[0]:
            self.nvim.err_write("Search query required\n")
            return

        query = ' '.join(args) if isinstance(args, list) else str(args)

        try:
            search_request = {
                'type': 'search_request',
                'query': query,
                'limit': 20
            }
            self.socket.send(json.dumps(search_request).encode())
            self.message_queue.put(('status', f"Searching for: {query}"))
        except Exception as e:
            self.nvim.err_write(f"Error searching: {e}\n")

