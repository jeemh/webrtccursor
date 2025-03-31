const express = require('express');
const http = require('http');
const socketIO = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = socketIO(server);

// 활성 사용자를 저장할 객체
const activeUsers = {};

io.on('connection', (socket) => {
  console.log('사용자 연결됨. 소켓 ID:', socket.id);
  
  // 사용자 등록
  socket.on('register', (userId) => {
    console.log('사용자 등록 요청:', userId, '소켓 ID:', socket.id);
    
    if (!userId) {
      console.error('오류: 빈 userId로 등록 시도');
      return;
    }
    
    activeUsers[userId] = socket.id;
    socket.userId = userId;
    console.log('현재 활성 사용자:', Object.keys(activeUsers));
    io.emit('updateUserList', Object.keys(activeUsers));
  });
  
  // 통화 요청
  socket.on('call', (data) => {
    const { target, offer } = data;
    console.log(`${socket.userId}가 ${target}에게 통화 요청`);
    
    if (activeUsers[target]) {
      io.to(activeUsers[target]).emit('incomingCall', {
        caller: socket.userId,
        offer: offer
      });
    }
  });
  
  // 통화 응답
  socket.on('answer', (data) => {
    const { target, answer } = data;
    console.log(`${socket.userId}가 ${target}에게 응답`);
    
    if (activeUsers[target]) {
      io.to(activeUsers[target]).emit('callAnswered', {
        answerer: socket.userId,
        answer: answer
      });
    }
  });
  
  // ICE 후보 전달
  socket.on('ice-candidate', (data) => {
    const { target, candidate } = data;
    
    if (activeUsers[target]) {
      io.to(activeUsers[target]).emit('ice-candidate', {
        sender: socket.userId,
        candidate: candidate
      });
    }
  });
  
  // 통화 종료
  socket.on('endCall', (data) => {
    const { target } = data;
    
    if (activeUsers[target]) {
      io.to(activeUsers[target]).emit('callEnded', {
        caller: socket.userId
      });
    }
  });
  
  // 연결 해제
  socket.on('disconnect', () => {
    if (socket.userId) {
      console.log('사용자 연결 해제:', socket.userId);
      delete activeUsers[socket.userId];
      io.emit('updateUserList', Object.keys(activeUsers));
    }
  });
});

const PORT = process.env.PORT || 5000;
server.listen(PORT, () => {
  console.log(`서버가 포트 ${PORT}에서 실행 중입니다`);
}); 